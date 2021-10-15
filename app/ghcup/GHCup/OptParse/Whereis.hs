{-# LANGUAGE CPP               #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes #-}

module GHCup.OptParse.Whereis where




import           GHCup
import           GHCup.Errors
import           GHCup.OptParse.Common
import           GHCup.Types
import           GHCup.Utils.Logger
import           GHCup.Utils.String.QQ

#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Data.Functor
import           Data.Maybe
import           Haskus.Utils.Variant.Excepts
import           Options.Applicative     hiding ( style )
import           Options.Applicative.Help.Pretty ( text )
import           Prelude                 hiding ( appendFile )
import           System.Exit
import           Text.PrettyPrint.HughesPJClass ( prettyShow )

import qualified Data.Text                     as T
import Control.Exception.Safe (MonadMask)
import System.FilePath (takeDirectory)
import GHCup.Types.Optics




    ----------------
    --[ Commands ]--
    ----------------


data WhereisCommand = WhereisTool Tool (Maybe ToolVersion)
                    | WhereisBaseDir
                    | WhereisBinDir
                    | WhereisCacheDir
                    | WhereisLogsDir
                    | WhereisConfDir





    ---------------
    --[ Options ]--
    ---------------


data WhereisOptions = WhereisOptions {
   directory :: Bool
}




    ---------------
    --[ Parsers ]--
    ---------------

          
whereisP :: Parser WhereisCommand
whereisP = subparser
  (commandGroup "Tools locations:" <> 
    command
      "ghc"
      (WhereisTool GHC <$> info
        ( optional (toolVersionArgument Nothing (Just GHC)) <**> helper )
        ( progDesc "Get GHC location"
        <> footerDoc (Just $ text whereisGHCFooter ))
      )
      <>
     command
      "cabal"
      (WhereisTool Cabal <$> info
        ( optional (toolVersionArgument Nothing (Just Cabal)) <**> helper )
        ( progDesc "Get cabal location"
        <> footerDoc (Just $ text whereisCabalFooter ))
      )
      <>
     command
      "hls"
      (WhereisTool HLS <$> info
        ( optional (toolVersionArgument Nothing (Just HLS)) <**> helper )
        ( progDesc "Get HLS location"
        <> footerDoc (Just $ text whereisHLSFooter ))
      )
      <>
     command
      "stack"
      (WhereisTool Stack <$> info
        ( optional (toolVersionArgument Nothing (Just Stack)) <**> helper )
        ( progDesc "Get stack location"
        <> footerDoc (Just $ text whereisStackFooter ))
      )
      <>
     command
      "ghcup"
      (WhereisTool GHCup <$> info ( pure Nothing <**> helper ) ( progDesc "Get ghcup location" ))
    ) <|> subparser ( commandGroup "Directory locations:"
      <>
     command
      "basedir"
      (info (pure WhereisBaseDir <**> helper)
            ( progDesc "Get ghcup base directory location" )
      )
      <>
     command
      "bindir"
      (info (pure WhereisBinDir <**> helper)
            ( progDesc "Get ghcup binary directory location" )
      )
      <>
     command
      "cachedir"
      (info (pure WhereisCacheDir <**> helper)
            ( progDesc "Get ghcup cache directory location" )
      )
      <>
     command
      "logsdir"
      (info (pure WhereisLogsDir <**> helper)
            ( progDesc "Get ghcup logs directory location" )
      )
      <>
     command
      "confdir"
      (info (pure WhereisConfDir <**> helper)
            ( progDesc "Get ghcup config directory location" )
      )
  )
 where
  whereisGHCFooter = [s|Discussion:
  Finds the location of a GHC executable, which usually resides in
  a self-contained "~/.ghcup/ghc/<ghcver>" directory.

Examples:
  # outputs ~/.ghcup/ghc/8.10.5/bin/ghc.exe
  ghcup whereis ghc 8.10.5
  # outputs ~/.ghcup/ghc/8.10.5/bin/
  ghcup whereis --directory ghc 8.10.5 |]

  whereisCabalFooter = [s|Discussion:
  Finds the location of a Cabal executable, which usually resides in
  "~/.ghcup/bin/".

Examples:
  # outputs ~/.ghcup/bin/cabal-3.4.0.0
  ghcup whereis cabal 3.4.0.0
  # outputs ~/.ghcup/bin
  ghcup whereis --directory cabal 3.4.0.0|]

  whereisHLSFooter = [s|Discussion:
  Finds the location of a HLS executable, which usually resides in
  "~/.ghcup/bin/".

Examples:
  # outputs ~/.ghcup/bin/haskell-language-server-wrapper-1.2.0
  ghcup whereis hls 1.2.0
  # outputs ~/.ghcup/bin/
  ghcup whereis --directory hls 1.2.0|]

  whereisStackFooter = [s|Discussion:
  Finds the location of a stack executable, which usually resides in
  "~/.ghcup/bin/".

Examples:
  # outputs ~/.ghcup/bin/stack-2.7.1
  ghcup whereis stack 2.7.1
  # outputs ~/.ghcup/bin/
  ghcup whereis --directory stack 2.7.1|]



    --------------
    --[ Footer ]--
    --------------


whereisFooter :: String
whereisFooter = [s|Discussion:
  Finds the location of a tool. For GHC, this is the ghc binary, that
  usually resides in a self-contained "~/.ghcup/ghc/<ghcver>" directory.
  For cabal/stack/hls this the binary usually at "~/.ghcup/bin/<tool>-<ver>".

Examples:
  # outputs ~/.ghcup/ghc/8.10.5/bin/ghc.exe
  ghcup whereis ghc 8.10.5
  # outputs ~/.ghcup/ghc/8.10.5/bin/
  ghcup whereis --directory ghc 8.10.5
  # outputs ~/.ghcup/bin/cabal-3.4.0.0
  ghcup whereis cabal 3.4.0.0
  # outputs ~/.ghcup/bin/
  ghcup whereis --directory cabal 3.4.0.0|]




    ---------------------------
    --[ Effect interpreters ]--
    ---------------------------


type WhereisEffects = '[ NotInstalled
                , NoToolVersionSet
                , NextVerNotFound
                , TagNotFound
                ]


runLeanWhereIs :: (MonadUnliftIO m, MonadIO m)
               => LeanAppState
               -> Excepts WhereisEffects (ReaderT LeanAppState m) a
               -> m (VEither WhereisEffects a)
runLeanWhereIs leanAppstate =
    -- Don't use runLeanAppState here, which is disabled on windows.
    -- This is the only command on all platforms that doesn't need full appstate.
    flip runReaderT leanAppstate
    . runE
      @WhereisEffects


runWhereIs :: (MonadUnliftIO m, MonadIO m)
           => (ReaderT AppState m (VEither WhereisEffects a) -> m (VEither WhereisEffects a))
           -> Excepts WhereisEffects (ReaderT AppState m) a
           -> m (VEither WhereisEffects a)
runWhereIs runAppState =
    runAppState
    . runE
      @WhereisEffects



    ------------------
    --[ Entrypoint ]--
    ------------------



whereis :: ( Monad m
         , MonadMask m
         , MonadUnliftIO m
         , MonadFail m
         )
      => WhereisCommand
      -> WhereisOptions
      -> (forall a. ReaderT AppState m (VEither WhereisEffects a) -> m (VEither WhereisEffects a))
      -> LeanAppState
      -> (ReaderT LeanAppState m () -> m ())
      -> m ExitCode
whereis whereisCommand whereisOptions runAppState leanAppstate runLogger = do
  Dirs{ .. }  <- runReaderT getDirs leanAppstate
  case (whereisCommand, whereisOptions) of
    (WhereisTool tool (Just (ToolVersion v)), WhereisOptions{..}) ->
      runLeanWhereIs leanAppstate (do
        loc <- liftE $ whereIsTool tool v
        if directory
        then pure $ takeDirectory loc
        else pure loc
        )
        >>= \case
              VRight r -> do
                liftIO $ putStr r
                pure ExitSuccess
              VLeft e -> do
                runLogger $ logError $ T.pack $ prettyShow e
                pure $ ExitFailure 30

    (WhereisTool tool whereVer, WhereisOptions{..}) -> do
      runWhereIs runAppState (do
        (v, _) <- liftE $ fromVersion whereVer tool
        loc <- liftE $ whereIsTool tool v
        if directory
        then pure $ takeDirectory loc
        else pure loc
        )
        >>= \case
              VRight r -> do
                liftIO $ putStr r
                pure ExitSuccess
              VLeft e -> do
                runLogger $ logError $ T.pack $ prettyShow e
                pure $ ExitFailure 30

    (WhereisBaseDir, _) -> do
      liftIO $ putStr baseDir
      pure ExitSuccess

    (WhereisBinDir, _) -> do
      liftIO $ putStr binDir
      pure ExitSuccess

    (WhereisCacheDir, _) -> do
      liftIO $ putStr cacheDir
      pure ExitSuccess

    (WhereisLogsDir, _) -> do
      liftIO $ putStr logsDir
      pure ExitSuccess

    (WhereisConfDir, _) -> do
      liftIO $ putStr confDir
      pure ExitSuccess
