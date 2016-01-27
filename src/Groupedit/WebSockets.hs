{-# LANGUAGE OverloadedStrings #-}

module Groupedit.WebSockets where

import Network.WebSockets as WS
import Control.Concurrent.STM (atomically, newTChan, writeTChan)
import Data.Text (Text)
import qualified Data.Text as T
import Control.Concurrent.Async (withAsync)
import Control.Exception (bracket_, try)

import Groupedit.Data

readSocket :: WS.Connection -> IO (Either WS.ConnectionException Text)
readSocket conn = try (WS.receiveData conn)

socketListener :: AuthFunc -> ServerState -> ServerApp
socketListener authFunc server pending = do
    conn <- WS.acceptRequest pending
    WS.forkPingThread conn 30
    chan <- atomically $ newTChan
    withAsync (lineSender conn chan) $ \a -> do
        eitherFirstLine <- readSocket conn
        case eitherFirstLine of
            Left err -> case err of
                -- We should note any parse exceptions. If they closed the connection
                -- without sending anything that's fine, so we won't report that.
                WS.ParseException str -> putStrLn $ "ERROR:ParseException:" ++ str
                _ -> return ()
            Right firstLine -> do
                authResult <- authFunc firstLine
                case authResult of
                    Left errMsg -> atomically $ writeTChan chan errMsg
                    Right info -> do
                        ac <- mkActiveClient conn chan info
                        roomName <- either (const "test") id <$> readSocket conn
                        bracket_
                            (atomically $ joinClient ac roomName server)
                            (atomically $ partClient ac roomName server)
                            (coreLoop ac roomName server)

coreLoop :: ActiveClient -> Text -> ServerState -> IO ()
coreLoop ac roomName server = do
    eitherMessage <- readSocket (getActiveConnection ac)
    case eitherMessage of
        Left err -> do
            -- The ConnectionException is one of three cases:
            -- * ParseException, we should note these probably.
            -- * CloseRequest, the library finalizes this for us once we end this thread.
            -- * ConnectionClosed, an RFC violation, and also their fault, so we just exit.
            case err of
                -- We could potentially recover from this, but in this version it just kills
                -- your connection for simplicity.
                WS.ParseException str -> putStrLn $ "ERROR:ParseException:" ++ str
                _ -> return ()
        Right line -> do
            putStrLn $ "DEBUG:" ++ T.unpack line
            -- First we have to parse the line, and commit it.
            let edits = parseOps line
            atomically $ do
                editServer roomName edits server
                broadcast ac roomName line server
            coreLoop ac roomName server
