{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeFamilies        #-}
module Haskell.Ide.Engine.Plugin.Bios(setTypecheckedModule, biosDescriptor) where

import           Bag
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.Function
import           Data.IORef
import           Data.List
import qualified Data.Map.Strict                   as Map
import           Data.Maybe
import           Data.Monoid ((<>))
import qualified Data.Set                          as Set
import qualified Data.Text                         as T
import           ErrUtils
import           Name
import           GHC.Generics

import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import qualified Haskell.Ide.Engine.Plugin.HieExtras as Hie
import           Haskell.Ide.Engine.ArtifactMap
import qualified Language.Haskell.LSP.Types        as LSP

import qualified GhcMod                            as GM
import qualified GhcMod.Error                      as GM
import qualified GhcMod.Gap                        as GM
import qualified GhcMod.Monad                      as GM
import qualified GhcMod.SrcUtils                   as GM

import           DynFlags
import           GHC
import           IOEnv                             as G
import           HscTypes
import           TcRnTypes
import           Outputable hiding ((<>))
-- This function should be defined in HIE probably, nothing in particular
-- to do with BIOS
import qualified HIE.Bios.GHCApi as BIOS (withDynFlags, CradleError)
import qualified HIE.Bios as BIOS

import System.Directory


-- ---------------------------------------------------------------------

biosDescriptor :: PluginId -> PluginDescriptor
biosDescriptor plId = PluginDescriptor
  { pluginId = plId
  , pluginName = "bios"
  , pluginDesc = "bios"
  , pluginCommands =
      [ PluginCommand "check" "check a file for GHC warnings and errors" checkCmd ]
  , pluginCodeActionProvider = Nothing
  , pluginDiagnosticProvider = Nothing
  , pluginHoverProvider = Nothing
  , pluginSymbolProvider = Nothing
  , pluginFormattingProvider = Nothing
  }

-- ---------------------------------------------------------------------

type Diagnostics = Map.Map Uri (Set.Set Diagnostic)
type AdditionalErrs = [T.Text]

checkCmd :: CommandFunc Uri (Diagnostics, AdditionalErrs)
checkCmd = CmdSync setTypecheckedModule

-- ---------------------------------------------------------------------

lspSev :: Severity -> DiagnosticSeverity
lspSev SevWarning = DsWarning
lspSev SevError   = DsError
lspSev SevFatal   = DsError
lspSev SevInfo    = DsInfo
lspSev _          = DsInfo

-- | Turn a 'SourceError' into the HIE 'Diagnostics' format.
srcErrToDiag :: MonadIO m
  => DynFlags
  -> (FilePath -> FilePath)
  -> SourceError -> m (Diagnostics, AdditionalErrs)
srcErrToDiag df rfm se = do
  debugm "in srcErrToDiag"
  let errMsgs = bagToList $ srcErrorMessages se
      processMsg err = do
        let sev = Just DsError
            unqual = errMsgContext err
            st = GM.mkErrStyle' df unqual
            msgTxt = T.pack $ renderWithStyle df (pprLocErrMsg err) st
        eloc <- srcSpan2Loc rfm $ errMsgSpan err
        case eloc of
          Right (Location uri range) ->
            return $ Right (uri, Diagnostic range sev Nothing (Just "bios") msgTxt Nothing)
          Left _ -> return $ Left msgTxt
      processMsgs [] = return (Map.empty,[])
      processMsgs (x:xs) = do
        res <- processMsg x
        (m,es) <- processMsgs xs
        case res of
          Right (uri, diag) ->
            return (Map.insertWith Set.union uri (Set.singleton diag) m, es)
          Left e -> return (m, e:es)
  processMsgs errMsgs


-- | Run a Ghc action and capture any diagnostics and errors produced.
captureDiagnostics :: (GM.MonadIO m, GhcMonad m)
  => (FilePath -> FilePath)
  -> m r
  -> m (Diagnostics, AdditionalErrs, Maybe r)
captureDiagnostics rfm action = do
  env <- getSession
  diagRef <- liftIO $ newIORef Map.empty
  errRef <- liftIO $ newIORef []
  let setLogger df = df { log_action = logDiag rfm errRef diagRef }
      setDeferTypedHoles = setGeneralFlag' Opt_DeferTypedHoles
      ghcErrRes msg = do
        diags <- liftIO $ readIORef diagRef
        errs <- liftIO $ readIORef errRef
        return (diags, (T.pack msg) : errs, Nothing)
      to_diag x = do
        (d1, e1) <- srcErrToDiag (hsc_dflags env) rfm x
        diags <- liftIO $ readIORef diagRef
        errs <- liftIO $ readIORef errRef
        return (Map.unionWith Set.union d1 diags, e1 ++ errs, Nothing)


      handlers = errorHandlers ghcErrRes to_diag
      action' = do
        r <- BIOS.withDynFlags (setLogger . setDeferTypedHoles) action
        diags <- liftIO $ readIORef diagRef
        errs <- liftIO $ readIORef errRef
        return (diags,errs, Just r)
  GM.gcatches action' handlers

-- | Create a 'LogAction' which will be invoked by GHC when it tries to
-- write anything to `stdout`.
logDiag :: (FilePath -> FilePath) -> IORef AdditionalErrs -> IORef Diagnostics -> LogAction
-- type LogAction = DynFlags -> WarnReason -> Severity -> SrcSpan -> PprStyle -> MsgDoc -> IO ()
logDiag rfm eref dref df _reason sev spn style msg = do
  eloc <- srcSpan2Loc rfm spn
  let msgTxt = T.pack $ renderWithStyle df msg style
  case eloc of
    Right (Location uri range) -> do
      let update = Map.insertWith Set.union uri l
            where l = Set.singleton diag
          diag = Diagnostic range (Just $ lspSev sev) Nothing (Just "bios") msgTxt Nothing
      debugm $ "Writing diag" <> (show diag)
      modifyIORef' dref update
    Left _ -> do
      debugm $ "Writing err" <> (show msgTxt)
      modifyIORef' eref (msgTxt:)
      return ()


errorHandlers :: (String -> m a) -> (SourceError -> m a) -> [GM.GHandler m a]
errorHandlers ghcErrRes renderSourceError = handlers
  where
      -- ghc throws GhcException, SourceError, GhcApiError and
      -- IOEnvFailure. ghc-mod-core throws GhcModError.
      handlers =
        [ GM.GHandler $ \(ex :: IOEnvFailure) ->
            ghcErrRes (show ex)
        , GM.GHandler $ \(ex :: GhcApiError) ->
            ghcErrRes (show ex)
        , GM.GHandler $ \(ex :: SourceError) ->
            renderSourceError ex
        , GM.GHandler $ \(ex :: IOError) ->
            ghcErrRes (show ex)
        , GM.GHandler $ \(ex :: BIOS.CradleError) ->
            ghcErrRes (show ex)
        ]


-- | Load a module from a filepath into the cache, first check the cache
-- to see if it's already there.
setTypecheckedModule :: Uri -> IdeGhcM (IdeResult (Diagnostics, AdditionalErrs))
setTypecheckedModule uri =
  pluginGetFile "setTypecheckedModule: " uri $ \fp -> do
    debugm "setTypecheckedModule: before ghc-mod"
    debugm "Loading file"
    -- mapped_fp <- persistVirtualFile uri
    -- ifCachedModuleM mapped_fp (setTypecheckedModule_load uri) cont
    setTypecheckedModule_load uri
  where
    cont :: TypecheckedModule -> CachedInfo
         -> IdeGhcM (IdeResult (Diagnostics, AdditionalErrs))
    cont _ _ = do
      debugm ("Using cache" ++ show uri)
      return (IdeResultOk (Map.empty, []))

-- Hacky, need to copy hs-boot file if one exists for a module
-- This is because the virtual file gets created at VFS-1234.hs and
-- then GHC looks for the boot file at VFS-1234.hs-boot
--
-- This strategy doesn't work if the user wants to edit the boot file but
-- not save it and expect the VFS to save them. However, I expect that HIE
-- already didn't deal with boot files correctly.
copyHsBoot :: FilePath -> FilePath -> IO ()
copyHsBoot fp mapped_fp = do
  ex <- doesFileExist (fp <> "-boot")
  if ex
    then copyFile (fp <> "-boot") (mapped_fp <> "-boot")
    else return ()


-- | Actually load the module if it's not in the cache
setTypecheckedModule_load :: Uri -> IdeGhcM (IdeResult (Diagnostics, AdditionalErrs))
setTypecheckedModule_load uri =
  pluginGetFile "setTypecheckedModule: " uri $ \fp -> do
    debugm "setTypecheckedModule: before ghc-mod"
    debugm "Loading file"
    mapped_fp <- persistVirtualFile uri
    liftIO $ copyHsBoot fp mapped_fp
    rfm <- reverseFileMap
    (diags', errs, mmods) <- (captureDiagnostics rfm $ BIOS.loadFile (fp, mapped_fp))
    debugm "File, loaded"
    canonUri <- canonicalizeUri uri
    let diags = Map.insertWith Set.union canonUri Set.empty diags'
    debugm "setTypecheckedModule: after ghc-mod"
    debugm ("Diags: " <> show diags')
    let collapse Nothing = (Nothing, [])
        collapse (Just (n, xs)) = (n, xs)

    diags2 <- case collapse mmods of
      --Just (Just pm, Nothing) -> do
      --  debugm $ "setTypecheckedModule: Did get parsed module for: " ++ show fp
       -- cacheModule fp (Left pm)
       -- debugm "setTypecheckedModule: done"
      --  return diags

      (Just tm, ts) -> do
        debugm $ "setTypecheckedModule: Did get typechecked module for: " ++ show fp
        --sess <- fmap GM.gmgsSession . GM.gmGhcSession <$> GM.gmsGet

        -- set the session before we cache the module, so that deferred
        -- responses triggered by cacheModule can access it
        --modifyMTS (\s -> s {ghcSession = sess})
        cacheModules rfm ts
        --cacheModules rfm [tm]
        debugm "setTypecheckedModule: done"
        return diags

      (Nothing, ts) -> do
        debugm $ "setTypecheckedModule: Didn't get typechecked or parsed module for: " ++ show fp
        --debugm $ "setTypecheckedModule: errs: " ++ show errs
        cacheModules rfm ts
        failModule fp

        let sev = Just DsError
            range = Range (Position 0 0) (Position 1 0)
            msgTxt = T.unlines errs
        let d = Diagnostic range sev Nothing (Just "bios") msgTxt Nothing
        return $ Map.insertWith Set.union canonUri (Set.singleton d) diags

    return $ IdeResultOk (diags2,errs)

