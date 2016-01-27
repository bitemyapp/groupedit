
module Main where

import System.Environment (getArgs)
import Control.Concurrent.STM (atomically, newTVar)
import Network.WebSockets (runServer)

import Groupedit.Data
import Groupedit.WebSockets

main :: IO ()
main = do
    argsInts <- (fmap.fmap) read getArgs
    case argsInts of
        [portNum] -> do
            putStrLn $ "Starting up on port " ++ show portNum
            server <- atomically newServer 
            runServer "0.0.0.0" portNum (socketListener alwaysAuth server)
        _ -> putStrLn "USAGE: strifeserver <portNumber>"

-- TODO: make this actually authenticate.
alwaysAuth :: AuthFunc
alwaysAuth credText = return $ Right $ ClientInfo {getInfoSiteID=5,getInfoUsername=credText}
