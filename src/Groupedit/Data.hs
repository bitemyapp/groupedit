{-# LANGUAGE OverloadedStrings #-}

module Groupedit.Data where

import Network.WebSockets as WS
import Data.Unique
import Data.List (foldl')
import Data.Maybe (fromMaybe,catMaybes)
import Data.Monoid ((<>))
import Data.Foldable (toList)
import Data.Sequence (Seq)
import qualified Data.Sequence as Se
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)
import Control.Concurrent.STM
import STMContainers.Map (Map)
import qualified STMContainers.Map as M
import Focus
import Control.Monad (forever)
import Control.Exception (try)

-- -- -- -- -- -- -- -- -- --
-- ActiveClient Section
-- -- -- -- -- -- -- -- -- --

{-| An AuthFunc is a function that takes the opening line of the websocket,
does some sort of computation, and returns either an error message (that will
be sent back to the user before their connection is closed) or a ClientInfo
to use for the duration of the connection.
-}
type AuthFunc = Text -> IO (Either Text ClientInfo)

{-| A ClientInfo is the things that the authentication function will
give us upon a successful authentication.
-} 
data ClientInfo = ClientInfo {
    getInfoSiteID :: Int,
    getInfoUsername :: Text
    } deriving (Eq, Ord, Show)

{-| An ActiveClient packages the data from a ClientInfo up with
a TChan of pending outbound messages, a websocket, and a Unique value.
An ActiveClient is Eq and Ord based on the Unique value. They Show with
just their username.
-}
data ActiveClient = ActiveClient {
    getActiveUID :: Unique,
    getActiveSiteID :: Int,
    getActiveUsername :: Text,
    getActiveChannel :: TChan Text,
    getActiveConnection :: WS.Connection
    }

instance Eq ActiveClient where
    a == b = getActiveUID a == getActiveUID b

instance Ord ActiveClient where
    compare a b = compare (getActiveUID a) (getActiveUID b)

instance Show ActiveClient where
    show ac = "ActiveClient<" ++ show (getActiveUsername ac) ++ ">"

bufferLine :: Text -> ActiveClient -> STM ()
bufferLine line ac = writeTChan (getActiveChannel ac) line

{-| An eternal loop that reads from the out-channel and then sends those
message into the websocket. Run this using withAsync for an easy time.
-}
lineSender :: ActiveClient -> IO loop
lineSender ac = forever $ do
    line <- atomically $ readTChan (getActiveChannel ac)
    try $ WS.sendTextData (getActiveConnection ac) line :: IO (Either WS.ConnectionException ())

-- -- -- -- -- -- -- -- -- --
-- ServerRoom Section
-- -- -- -- -- -- -- -- -- --

{-| A ServerRoom has a name, a list of clients "in" the room, and a
sequence of lines reprisenting the current text that everyone in the room
should see.
-}
data ServerRoom = ServerRoom {
    getRoomName :: Text,
    getRoomClients :: [ActiveClient],
    getRoomLines :: Seq Text
    } deriving (Eq, Show)

-- | Creates a new room that is empty and blank, using the name specified.
mkRoom :: Text -> ServerRoom
mkRoom name = ServerRoom name [] (Se.singleton "")

-- | Adds an ActiveClient to a ServerRoom.
addUserRoom :: ActiveClient -> ServerRoom -> ServerRoom
addUserRoom ac room@(ServerRoom {getRoomClients=clients}) = room {getRoomClients= ac : clients}

-- | Removes the ActiveClient from of the ServerRoom.
delUserRoom :: ActiveClient -> ServerRoom -> ServerRoom
delUserRoom ac room@(ServerRoom {getRoomClients=clients}) = room {getRoomClients= filter (/= ac) clients}

-- | An EditOp lets you update a line, insert a line, or delete a line.
data EditOp = Update Int Text
            | Insert Int Text
            | Delete Int
            deriving (Eq, Show)

-- | Parse a single part of a line into an EditOp, if possible.
parseOneOp :: Text -> Maybe EditOp
parseOneOp t = let
    (opName,rest) = T.drop 1 <$> T.breakOn " " t
    in case opName of
        "update" -> let
            (num,tx) = T.drop 1 <$> T.breakOn " " rest
            num' = readMaybe (T.unpack num)
            in fmap (\i -> Update i tx) num'
        "insert" -> let
            (num,tx) = T.drop 1 <$> T.breakOn " " rest
            num' = readMaybe (T.unpack num)
            in fmap (\i -> Insert i tx) num'
        "delete" -> Delete <$> readMaybe (T.unpack rest)
        _ -> Nothing

-- | Parse an incoming line into the EditOps it reprisents. Ops are newline seperated.
parseOps :: Text -> [EditOp]
parseOps t = catMaybes $ map parseOneOp $ T.split (=='\n') t

-- | Performs a single edit to a Seq Text, for use with foldl'.
editSeq :: Seq Text -> EditOp -> Seq Text
editSeq s (Update i t) = Se.update i t s
editSeq s (Insert i t) = case i of
    0 -> t Se.<| s
    _ -> if i == length s
        then s Se.|> t
        else let (before, after) = Se.splitAt i s in (before Se.|> t) Se.>< after
editSeq s (Delete i) = case i of
    0 -> Se.drop 1 s
    _ -> let (before, after) = Se.splitAt (i-1) s in before Se.>< (Se.drop 1 after)

-- | Applies a list of edits to the lines of a ServerRoom, giving the new ServerRoom.
applyEdits :: [EditOp] -> ServerRoom -> ServerRoom
applyEdits edits room@(ServerRoom {getRoomLines=lines}) = room{getRoomLines=foldl' editSeq lines edits}

{-| Given a ServerRoom, produce the Text that, if passed to parseOps, would parse into
the EditOp list required to turn a blank room's lines into the given room's lines.
-}
rebuildText :: ServerRoom -> Text
rebuildText (ServerRoom {getRoomLines=lines}) = let
    toOp (lnum,ltx) = case lnum of
        0 -> "update "<>T.pack (show lnum)<>" "<>ltx
        _ -> "insert "<>T.pack (show lnum)<>" "<>ltx
    in T.intercalate "\n" $ map toOp (zip [0..] (toList lines))

-- -- -- -- -- -- -- -- -- --
-- ServerState Section
-- -- -- -- -- -- -- -- -- --

{-| A ServerState maps room names to ServerRoom values. This map is
an STM-specialized hash table that you edit in STM.
-}
type ServerState = Map Text ServerRoom

-- | Creates a new, empty server.
newServer :: STM ServerState
newServer = M.new

{-| Adds the client specified to the room specified, including
the creation of the room if it's not already within the room. Also
buffers the room's current text into the client's output channel.
The user's arrival is announced to everyone already in the room.
-}
joinClient :: ActiveClient -> Text -> ServerState -> STM ()
joinClient ac roomName = M.focus (alterM addOrNew) roomName
    where
    addOrNew maybeOld = let room = fromMaybe (mkRoom roomName) maybeOld in do
        let initLine = rebuildText room
        let joinMessage = "join " <> getActiveUsername ac
        bufferLine joinMessage ac
        bufferLine initLine ac
        mapM_ (bufferLine joinMessage) (getRoomClients room)
        return (Just $ addUserRoom ac room)

{-| Removes the cilent specified from the room specified. If the room
is empty after that then the room is removed from the server.
-}
partClient :: ActiveClient -> Text -> ServerState -> STM ()
partClient ac roomName = M.focus (alterM removeIfEmpty) roomName
-- Technically we can Eta reduce the above, but symmetry with joinClient demands that we don't.
    where
    removeIfEmpty maybeOld = let room = fromMaybe (mkRoom "there's always an old room") maybeOld in do
        let partMessage = "part " <> getActiveUsername ac
        mapM_ (bufferLine partMessage) (getRoomClients room)
        let newRoom = delUserRoom ac room
        if length (getRoomClients newRoom) < 1
            then return Nothing
            else return (Just newRoom)

{-| Given a client, roomName, message, and server, sends the message to
all clients within the room specified except for the client specified (so that
users don't end up getting their own messages).
-}
broadcast :: ActiveClient -> Text -> Text -> ServerState -> STM ()
broadcast ac roomName message server = do
    maybeRoom <- M.lookup roomName server
    case maybeRoom of
        Nothing -> return () -- It's probably an error of some sort if you actually hit this case.
        Just room -> mapM_ (bufferLine message) (getRoomClients room)
