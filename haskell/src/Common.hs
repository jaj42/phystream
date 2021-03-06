{-# LANGUAGE GADTs, OverloadedStrings #-}

module Common where

import qualified System.IO as SysIO
import qualified System.Hardware.Serialport as S
import qualified System.ZMQ4 as Z
import qualified System.Directory as D

import           Control.Lens
import           Control.Monad (forever)
import qualified Control.Exception as Ex

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Attoparsec.Text
import           Data.List.NonEmpty (NonEmpty(..))
import qualified Data.MessagePack as M
import qualified Data.ConfigFile as CF
import qualified Data.HashMap as HM
import           Data.Monoid ((<>))

import           Pipes
import           Pipes.Core
import qualified Pipes.Prelude as P
import qualified Pipes.Text as PT
import qualified Pipes.Parse as PP
import qualified Pipes.Attoparsec as PA
import qualified Pipes.ZMQ4 as PZ


type DevPath = String

withSerial :: DevPath -> S.SerialPortSettings -> (SysIO.Handle -> IO a) -> IO a
withSerial dev settings = Ex.bracket (S.hOpenSerial dev settings) SysIO.hClose

withBSerial :: DevPath -> S.SerialPortSettings -> (S.SerialPort -> IO a) -> IO a
withBSerial dev settings = Ex.bracket (S.openSerial dev settings) S.closeSerial

fromHandleForever :: MonadIO m => SysIO.Handle -> Producer Text m ()
fromHandleForever h = forever go
  where
      go = do txt <- liftIO (T.hGetChunk h)
              if T.null txt then return ()
                            else yield txt

lineByLine :: MonadIO m => Producer Text m () -> Producer Text m ()
lineByLine = view PT.unlines . view PT.lines

zmqConsumer :: (PZ.MonadSafe m, PZ.Base m ~ IO)
    => Z.Context -> String -> Consumer PT.ByteString m ()
zmqConsumer ctx dest = P.map (:| []) >-> PZ.setupConsumer ctx Z.Pub (`Z.connect` dest)

dropLog :: (Show a, MonadIO m) => PA.ParsingError -> Pipe a a m ()
dropLog errmsg = await >>= liftIO.printErr errmsg >> cat
  where
    printErr e s = SysIO.hPutStrLn SysIO.stderr (show e ++ ": " ++ show s)

parseProxy :: (Monad m) => Parser b -> Text -> Proxy a Text a (Maybe b) m ()
parseProxy parser = goNew
  where
    goNew input = decideNext $ parse parser input
    goPart cont input = decideNext $ feed cont input
    reqWith dat = respond dat >>= request
    decideNext result =
        case result of
            Done r d   -> reqWith (Just d) >>= goNew.(r <>)
            Partial{}  -> reqWith Nothing >>= goPart result
            Fail{}     -> reqWith Nothing >>= goNew

parseForever :: (MonadIO m) => Parser a -> Producer Text m () -> Producer a m ()
parseForever parser inflow = do
    (result, remainder) <- lift $ PP.runStateT (PA.parse parser) inflow
    case result of
         Nothing -> return ()
         Just e  -> case e of
                         -- Drop current line on parsing error and continue
                         Left err    -> parseForever parser (remainder >-> dropLog err)
                         Right entry -> yield entry >> parseForever parser remainder

encodeToMsgPack :: (MonadIO m, M.MessagePack b) => B.ByteString -> (a -> b) -> Pipe a B.ByteString m ()
encodeToMsgPack prefix preprocess = P.map $ \dat
    -> prefix <> " " <> (BL.toStrict . M.pack . preprocess $ dat)

getConfigFor :: CF.SectionSpec -> IO (HM.Map String String)
getConfigFor section = do
    configdir <- D.getXdgDirectory D.XdgConfig "phystream"
    cfgfile <- D.canonicalizePath (configdir ++ "/config.ini")
    mcp <- CF.readfile CF.emptyCP cfgfile
    let result = do
            configparser <- mcp
            CF.items configparser section
    case result of
         Left _  -> return HM.empty
         Right r -> return $ HM.fromList r
