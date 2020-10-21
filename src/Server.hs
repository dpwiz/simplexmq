{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Server (runSMPServer) where

import ConnStore
import ConnStore.STM (ConnStore)
import Control.Concurrent.STM (stateTVar)
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as M
import Data.Time.Clock
import Env.STM
import MsgStore
import MsgStore.STM (MsgQueue)
import Transmission
import Transport
import UnliftIO.Async
import UnliftIO.Concurrent
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM

runSMPServer :: (MonadRandom m, MonadUnliftIO m) => Config -> m ()
runSMPServer cfg@Config {tcpPort} = do
  env <- newEnv cfg
  runReaderT smpServer env
  where
    smpServer :: (MonadUnliftIO m, MonadReader Env m) => m ()
    smpServer = do
      s <- asks server
      race_ (runTCPServer tcpPort runClient) (serverThread s)

    serverThread :: MonadUnliftIO m => Server -> m ()
    serverThread Server {subscribedQ, subscribers} = forever . atomically $ do
      (rId, clnt) <- readTBQueue subscribedQ
      cs <- readTVar subscribers
      case M.lookup rId cs of
        Just Client {rcvQ} -> writeTBQueue rcvQ (rId, Cmd SBroker END)
        Nothing -> return ()
      writeTVar subscribers $ M.insert rId clnt cs

runClient :: (MonadUnliftIO m, MonadReader Env m) => Handle -> m ()
runClient h = do
  putLn h "Welcome to SMP"
  q <- asks $ queueSize . config
  c <- atomically $ newClient q
  s <- asks server
  raceAny_ [send h c, client c s, receive h c]
    `finally` cancelSubscribers c

cancelSubscribers :: (MonadUnliftIO m) => Client -> m ()
cancelSubscribers Client {subscriptions} = do
  cs <- readTVarIO subscriptions
  forM_ cs cancelSub

cancelSub :: (MonadUnliftIO m) => Sub -> m ()
cancelSub = \case
  Sub {subThread = SubThread t} -> killThread t
  _ -> return ()

raceAny_ :: MonadUnliftIO m => [m a] -> m ()
raceAny_ = r []
  where
    r as (m : ms) = withAsync m $ \a -> r (a : as) ms
    r as [] = void $ waitAnyCancel as

receive :: (MonadUnliftIO m, MonadReader Env m) => Handle -> Client -> m ()
receive h Client {rcvQ} = forever $ do
  (signature, (connId, cmdOrError)) <- tGet fromClient h
  -- TODO maybe send Either to queue?
  signed <- case cmdOrError of
    Left e -> return . (connId,) . Cmd SBroker $ ERR e
    Right cmd -> verifyTransmission signature connId cmd
  atomically $ writeTBQueue rcvQ signed

send :: MonadUnliftIO m => Handle -> Client -> m ()
send h Client {sndQ} = forever $ do
  signed <- atomically $ readTBQueue sndQ
  tPut h (B.empty, signed)

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => Signature -> ConnId -> Cmd -> m Signed
verifyTransmission signature connId cmd = do
  (connId,) <$> case cmd of
    Cmd SBroker _ -> return $ smpErr INTERNAL -- it can only be client command, because `fromClient` was used
    Cmd SRecipient (CONN _) -> return cmd
    Cmd SRecipient _ -> withConnection SRecipient $ verifySignature . recipientKey
    Cmd SSender (SEND _) -> withConnection SSender $ verifySend . senderKey
  where
    withConnection :: SParty (p :: Party) -> (Connection -> m Cmd) -> m Cmd
    withConnection party f = do
      store <- asks connStore
      conn <- atomically $ getConn store party connId
      either (return . smpErr) f conn
    verifySend :: Maybe PublicKey -> m Cmd
    verifySend
      | B.null signature = return . maybe cmd (const authErr)
      | otherwise = maybe (return authErr) verifySignature
    -- TODO stub
    verifySignature :: PublicKey -> m Cmd
    verifySignature key = return $ if signature == key then cmd else authErr

    smpErr e = Cmd SBroker $ ERR e
    authErr = smpErr AUTH

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {subscriptions, rcvQ, sndQ} Server {subscribedQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Signed -> m Signed
    processCommand (connId, cmd) = do
      st <- asks connStore
      case cmd of
        Cmd SBroker END -> unsubscribeConn >> return (connId, cmd)
        Cmd SBroker _ -> return (connId, cmd)
        Cmd SSender (SEND msgBody) -> sendMessage st msgBody
        Cmd SRecipient command -> case command of
          CONN rKey -> createConn st rKey
          SUB -> subscribeConn connId
          ACK -> acknowledgeMsg
          KEY sKey -> okResponse <$> atomically (secureConn st connId sKey)
          OFF -> okResponse <$> atomically (suspendConn st connId)
          DEL -> okResponse <$> atomically (deleteConn st connId)
      where
        ok :: Signed
        ok = (connId, Cmd SBroker OK)

        okResponse :: Either ErrorType () -> Signed
        okResponse = mkSigned connId . either ERR (const OK)

        createConn :: ConnStore -> RecipientKey -> m Signed
        createConn st rKey = mkSigned B.empty <$> addSubscribe
          where
            addSubscribe = do
              addConnRetry 3 >>= \case
                Left e -> return $ ERR e
                Right (rId, sId) -> do
                  void $ subscribeConn rId
                  return $ IDS rId sId

            addConnRetry :: Int -> m (Either ErrorType (RecipientId, SenderId))
            addConnRetry 0 = return $ Left INTERNAL
            addConnRetry n = do
              ids <- getIds
              atomically (addConn st rKey ids) >>= \case
                Left DUPLICATE -> addConnRetry $ n - 1
                Left e -> return $ Left e
                Right _ -> return $ Right ids

            getIds :: m (RecipientId, SenderId)
            getIds = do
              n <- asks $ connIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        subscribeConn :: RecipientId -> m Signed
        subscribeConn rId = do
          atomically $ do
            cs <- readTVar subscriptions
            case M.lookup rId cs of
              Just Sub {delivered} -> void $ tryTakeTMVar delivered
              Nothing -> do
                writeTBQueue subscribedQ (rId, clnt)
                sub <- newSubscription
                writeTVar subscriptions $ M.insert rId sub cs
          deliverMessage tryPeekMsg rId

        unsubscribeConn :: m ()
        unsubscribeConn = do
          sub <- atomically . stateTVar subscriptions $
            \cs -> (M.lookup connId cs, M.delete connId cs)
          mapM_ cancelSub sub

        acknowledgeMsg :: m Signed
        acknowledgeMsg = do
          dlvrd <- atomically $ do
            cs <- readTVar subscriptions
            case M.lookup connId cs of
              Just s -> tryTakeTMVar (delivered s)
              Nothing -> return Nothing
          case dlvrd of
            Just () -> deliverMessage tryDelPeekMsg connId
            Nothing -> return . mkSigned connId $ ERR PROHIBITED

        sendMessage :: ConnStore -> MsgBody -> m Signed
        sendMessage st msgBody =
          atomically (getConn st SSender connId)
            >>= fmap (mkSigned connId) . either (return . ERR) storeMessage
          where
            mkMessage :: m Message
            mkMessage = do
              msgId <- asks (msgIdBytes . config) >>= randomId
              ts <- liftIO getCurrentTime
              return $ Message {msgId, ts, msgBody}

            storeMessage :: Connection -> m (Command 'Broker)
            storeMessage c = case status c of
              ConnActive -> do
                ms <- asks msgStore
                msg <- mkMessage
                atomically $ do
                  q <- getMsgQueue ms (recipientId c)
                  writeMsg q msg
                  return OK
              ConnOff -> return $ ERR AUTH

        deliverMessage :: (MsgQueue -> STM (Maybe Message)) -> RecipientId -> m Signed
        deliverMessage tryPeek rId = do
          ms <- asks msgStore
          q <- atomically $ getMsgQueue ms rId
          atomically (tryPeek q) >>= \case
            Just msg -> do
              atomically setDelivered
              return $ msgResponse rId msg
            Nothing -> forkSub q >> return ok
          where
            forkSub :: MsgQueue -> m ()
            forkSub q = do
              sub <- M.lookup rId <$> readTVarIO subscriptions
              case sub of
                Just Sub {subThread = NoSub} -> do
                  atomically . setSub $ \s -> s {subThread = SubPending}
                  t <- forkIO $ subscriber q
                  atomically . setSub $ \case
                    s@Sub {subThread = SubPending} -> s {subThread = SubThread t}
                    s -> s
                _ -> return ()

            subscriber :: MsgQueue -> m ()
            subscriber q = atomically $ do
              msg <- peekMsg q
              writeTBQueue sndQ $ msgResponse rId msg
              setSub (\s -> s {subThread = NoSub})
              setDelivered

            setSub :: (Sub -> Sub) -> STM ()
            setSub f = modifyTVar subscriptions $ M.adjust f rId

            setDelivered :: STM ()
            setDelivered =
              readTVar subscriptions
                >>= mapM_ (\s -> tryPutTMVar (delivered s) ()) . M.lookup rId

        mkSigned :: ConnId -> Command 'Broker -> Signed
        mkSigned cId command = (cId, Cmd SBroker command)

        msgResponse :: RecipientId -> Message -> Signed
        msgResponse rId Message {msgId, ts, msgBody} = mkSigned rId $ MSG msgId ts msgBody

randomId :: (MonadUnliftIO m, MonadReader Env m) => Int -> m Encoded
randomId n = do
  gVar <- asks idsDrg
  atomically (randomBytes n gVar)

randomBytes :: Int -> TVar ChaChaDRG -> STM ByteString
randomBytes n gVar = do
  g <- readTVar gVar
  let (bytes, g') = randomBytesGenerate n g
  writeTVar gVar g'
  return bytes
