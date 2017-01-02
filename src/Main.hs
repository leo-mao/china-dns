module Main where

import qualified ZhinaDNS as ZDNS
import IPSet
import Text.Parsec
import Parse
import qualified Log

import System.IO
import System.Log.Logger

import Network.Socket hiding (recv, recvFrom, send, sendTo)
import Network.Socket.ByteString 
import qualified Network.Socket.ByteString.Lazy as SL

import qualified Resolve.Types as R
import qualified Resolve.DNS.Transport.Helper.UDP as UDP
import qualified Resolve.DNS.Transport.Helper.LiveTCP as TCP
import qualified Resolve.DNS.Transport as Transport
import Resolve.DNS.Utils
import Resolve.DNS.Coding

import Resolve.Timeout
import qualified Resolve.Log as L

import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Builder
import Data.Maybe

import Control.Monad
import Control.Monad.STM
import Control.Monad.Trans.Class
import Control.Monad.Trans.Maybe

import Control.Concurrent
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TMVar

import System.Environment

import Control.Exception


nameM = "Main"

readChinaIP :: Handle -> IO (Either String [IPRange IPv4])
readChinaIP h = helper 0 []
  where helper i t = do
          done <- hIsEOF h
          if done then do
            return $ Right t
            else do
            l <- hGetLine h
            case parse (line i) "" l of
              Left e -> return $ Left $ show e
              Right ip' -> helper (i +1) (maybe t (\ip -> ip : t) ip')

main :: IO ()
main = do
  Log.setup
  
  let nameF = nameM ++ ".main"

  host <- lookupEnv "HOST"
  port <- lookupEnv "PORT"
  zhina_host <- lookupEnv "ZHINA_HOST"
  zhina_port <- lookupEnv "ZHINA_PORT"
  world_host <- lookupEnv "WORLD_HOST"
  world_port <- lookupEnv "WORLD_PORT"
  
  zhina_udp_timeout <- lookupEnv "ZHINA_UDP_TIMEOUT"
  zhina_tcp_timeout <- lookupEnv "ZHINA_TCP_TIMEOUT"
  world_tcp_timeout <- lookupEnv "WORLD_TCP_TIMEOUT"
  

  let host' = fromMaybe "127.0.0.1" host
  let port' = fromMaybe "5300" port
  let zhina_host' = fromMaybe "114.114.114.114" zhina_host
  let zhina_port' = fromMaybe "53" zhina_port
  let world_host' = fromMaybe "8.8.8.8" world_host
  let world_port' = fromMaybe "53" world_port


  let zhina_udp_timeout' = maybe 100000 read zhina_udp_timeout
  let zhina_tcp_timeout' = maybe 1000000 read zhina_tcp_timeout 
  let world_tcp_timeout' = maybe 5000000 read world_tcp_timeout 


  l' <- readChinaIP stdin
  l <- case l' of
    Left e -> error e
    Right l -> return l
  
  let ips = foldl (\a b -> add a b) create l
  infoM nameF $ (show $ size ips) ++  " china subnets loaded"


  let c_china_udp = UDP.Config {UDP.host = zhina_host', UDP.port = zhina_port', UDP.p_max = 4096}
  t_china_udp <- UDP.new $ c_china_udp
  r_china_udp <- Transport.new t_china_udp
  infoM nameF $ "created client: " ++ (show c_china_udp)

  let c_china_tcp = TCP.Config {TCP.host = zhina_host', TCP.port = zhina_port', TCP.passive = True}
  t_china_tcp <- TCP.new $ c_china_tcp
  r_china_tcp <- Transport.new t_china_tcp
  infoM nameF $ "created client: " ++ (show c_china_tcp)

  let c_world_tcp = TCP.Config {TCP.host = world_host', TCP.port = world_port', TCP.passive = True}
  t_world_tcp <- TCP.new $ c_world_tcp
  r_world_tcp <- Transport.new t_world_tcp
  infoM nameF $ "created client: " ++ (show c_world_tcp)

  let log = L.log (debugM "Main") (debugM "Main")
  let r_china_udp' = timeout zhina_udp_timeout' $ log $ decode $ R.resolve r_china_udp
  let r_china_tcp' = timeout zhina_tcp_timeout' $ log $ decode $ R.resolve r_china_tcp
  let r_world_tcp' = timeout world_tcp_timeout' $ log $ decode $ R.resolve r_world_tcp
  
  let r_udp = ZDNS.resolve $ ZDNS.Config
              { ZDNS.china = r_china_udp'
              , ZDNS.world = r_world_tcp'
              , ZDNS.chinaIP = ips
              }
          
      r_tcp = ZDNS.resolve $ ZDNS.Config
              { ZDNS.china = r_china_tcp'
              , ZDNS.world = r_world_tcp'
              , ZDNS.chinaIP = ips
              }
              
  void $ forkIO $ udp $ Config { resolve = encode $ r_udp
                                 , host = host'
                                 , port = port'
                                 }
           
  void $ forkIO $ tcp_listen $ Config { resolve = encode $ r_tcp
                                        , host = host'
                                        , port = port'
                                        }
  forever $ threadDelay 1000000

data Config = Config { resolve :: R.Resolve ByteString ByteString
                     , host :: String
                     , port :: String
                     }
    
udp :: Config  -> IO ()
udp c = do
  let nameF = nameM ++ ".udp"
  let maxLength = 512 -- 512B is max length of UDP message
                      -- due ot rfc1035
  
  infoM nameF $ "starting UDP server"
  let hints = defaultHints { addrSocketType = Datagram, addrFlags = [AI_ADDRCONFIG, AI_PASSIVE]}
  addr:_ <- getAddrInfo (Just hints) (Just $ host c) (Just $ port c)
  bracket 
    (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
    close
    (\sock -> do
        bind sock (addrAddress addr)
        infoM nameF $ "bound to " ++ (show $ addrAddress addr)
        forever $ do
          (a, sa) <- recvFrom sock maxLength
          forkIO $ do 
            b <- resolve c (BSL.fromStrict a)
            void $ sendTo sock (BSL.toStrict b) sa
    )
    
tcp_listen :: Config -> IO ()
tcp_listen c = do
  let nameF = nameM ++ ".tcp"
  infoM nameF "starting TCP server"
  let hints = defaultHints { addrSocketType = Stream, addrFlags = [AI_ADDRCONFIG, AI_PASSIVE]}
  addr:_ <- getAddrInfo (Just hints) (Just $ host c) (Just $ port c)
  bracket
    (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
    close
    (\sock -> do 
        bind sock (addrAddress addr)
        infoM nameF $ "bound to " ++ (show $ addrAddress addr)
        listen sock 5
        forever $ do
          bracketOnError
            (accept sock)
            (\(sock', _) -> close sock')
            (\(sock', sa) -> do 
                let nameConn = nameF ++ "." ++ (show sa)
                forkFinally (tcp sock' nameConn (resolve c)) (\_ -> close sock'))
    )


tcp sock' _ r = do
  qi <- newEmptyTMVarIO
  qo <- newEmptyTMVarIO
  si <- newTVarIO False
  so <- newTVarIO False

  bracket 
    (do
        -- thread receiving messages to qi
        ti <- forkFinally
          (do
              let recvAll' n = do  
                    bs <- SL.recv sock' n
                    when (BSL.length bs == 0) $ throwIO ThreadKilled
                    mappend (lazyByteString bs) <$> (recvAll' $ n - (BSL.length bs))
                  recvAll n = toLazyByteString <$> recvAll' n

              forever $ runMaybeT $ do
                n <- lift $ recvAll 2
                let n' = toWord16 (BSL.toStrict n)
                lift $ do 
                  bs <- recvAll $ fromIntegral n'
                  atomically $ putTMVar qi bs)
          (\_ -> atomically $ writeTVar si True)

        -- thread sending messages from qo
        to <- forkFinally
          (do
              let sendAll bs = if BSL.null bs  then
                                 return ()
                               else do
                    n <- SL.send sock' bs
                    sendAll (BSL.drop n bs)
              forever $ do
                bs <- atomically $ takeTMVar qo
                case safeFromIntegral $ BSL.length bs of
                  Nothing -> return ()
                  Just n -> do 
                    sendAll $ BSL.fromStrict $ fromWord16 n
                    sendAll bs)
          (\_ -> atomically $ writeTVar so True)
        return (ti, to)
    )
    (\(ti, to) -> do
        killThread ti
        killThread to
    )
    (\_ -> forever $ do
        a <- atomically $ do
          x <- readTVar si
          if x then tryTakeTMVar qi
            else Just <$> takeTMVar qi
        case a of
          Nothing -> throwIO ThreadKilled
          Just a' -> forkIO $ do 
            b <- r a'
            atomically $ do
              x <- readTVar so
              when (not x) $ putTMVar qo b
    )

