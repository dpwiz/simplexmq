module Main where

import Env.STM
import Server (runSMPServer)

cfg :: Config
cfg =
  Config
    { tcpPort = "5223",
      tbqSize = 16,
      queueIdBytes = 12,
      msgIdBytes = 6
    }

main :: IO ()
main = do
  putStrLn $ "Listening on port " ++ tcpPort cfg
  runSMPServer cfg