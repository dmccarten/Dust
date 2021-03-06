{-# LANGUAGE DeriveGeneric, DefaultSignatures #-} -- For automatic generation of cereal put and get

module Dust.Core.Protocol
(
 Session(..),
 Stream(..),
 StreamHeader(..),
 makeSession,
 makeEncrypt,
 makeDecrypt,
 makeHeader,
 makeStream,
 makeEncoder,
 getSession,
 getPacket,
 putSessionPacket
) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import GHC.Int
import Data.ByteString.Lazy (ByteString, append, toChunks)
import Data.Binary.Put (Put, putByteString)
import Data.Binary.Get (Get, getLazyByteString, runGet, runGetState)
import Network.Socket (Socket)
import Network.Socket.ByteString (recv, sendAll)
import System.IO (appendFile)

import Dust.Core.DustPacket
import Dust.Crypto.DustCipher
import Dust.Crypto.ECDH
import Dust.Crypto.Keys
import Dust.Model.TrafficModel

data Session = Session Keypair PublicKey IV deriving (Show)
data Stream = Stream StreamHeader CipherDataPacket deriving (Show)
data StreamHeader = StreamHeader PublicKey IV deriving (Show)

makeSession :: Keypair -> PublicKey -> IV -> Session
makeSession keypair publicKey iv = Session keypair publicKey iv

makeEncrypt :: Session -> (Plaintext -> Ciphertext)
makeEncrypt (Session (Keypair myPublic myPrivate) otherPublic iv) =
    let key = createShared myPrivate otherPublic
    in encrypt key iv

makeDecrypt :: Session -> (Ciphertext -> Plaintext)
makeDecrypt (Session (Keypair myPublic myPrivate) otherPublic iv) =
    let key = createShared myPrivate otherPublic
    in decrypt key iv

makeHeader :: PublicKey -> IV -> StreamHeader
makeHeader publicKey iv = StreamHeader publicKey iv

makeStream :: StreamHeader -> CipherDataPacket -> Stream
makeStream header cipherPacket = Stream header cipherPacket

makeEncoder :: Session -> (Plaintext -> Stream)
makeEncoder session@(Session (Keypair myPublic _) _ iv) =
    let header = makeHeader myPublic iv
        cipher = makeEncrypt session
        encrypter = encryptData cipher
        stream = makeStream header
    in stream . encrypter . makePlainPacket

getSession :: TrafficGenerator -> Keypair -> Socket -> IO Session
getSession gen keypair sock = do
    public <- readBytes gen sock 32 B.empty
    iv <- readBytes gen sock 16 B.empty
    return (Session keypair (PublicKey public) (IV iv))

getPacket :: TrafficGenerator -> Session -> Socket -> IO Plaintext
getPacket gen session sock = do
    putStrLn $ "Session: " ++ (show session)
    packetBytes <- readBytes gen sock 4 B.empty
    putStrLn $ "packetBytes: " ++ (show packetBytes)
    let cipherHeader = CipherHeader (Ciphertext packetBytes)
    putStrLn $ "cipherHeader: " ++ (show cipherHeader)
    let cipher = makeDecrypt session
    let plainPacketHeader = decryptHeader cipher cipherHeader
    putStrLn $ "plainPacketHeader: " ++ (show plainPacketHeader)
    let PlainHeader packetLength = plainPacketHeader
    putStrLn $ "packetLength: " ++ (show packetLength)
    let packetLen = (fromIntegral packetLength)::Int
    putStrLn $ "packetLen: " ++ (show packetLen)

    payloadBytes <- readBytes gen sock packetLen B.empty
    let ciphertext = Ciphertext payloadBytes
    return (cipher ciphertext)

readBytes :: TrafficGenerator -> Socket -> Int -> B.ByteString -> IO(B.ByteString)
readBytes gen sock maxLen buffer = do
    bs <- recv sock maxLen
    putStrLn $ "Read: " ++ (show $ B.length bs) ++ "/" ++ (show maxLen)
    let buff = B.append buffer bs
    let decoder = decodeContent gen
    let decoded = decoder buff
    let decodedLen = B.length decoded
    putStrLn $ "Decoded: " ++ (show decodedLen)
    if decodedLen >= maxLen
      then do
        putStrLn $ "Read result:" ++ (show (B.length decoded) ++ ":" ++ show (B.length buff)) ++ " " ++ (show decoded) ++ " -> " ++ (show buff)
        return $ B.take maxLen decoded
      else do
        result <- readMoreBytes gen sock maxLen buff
        return $ B.take maxLen result

readMoreBytes :: TrafficGenerator -> Socket -> Int -> B.ByteString -> IO B.ByteString
readMoreBytes gen sock maxLen buffer = do
    bs <- recv sock 1
    putStrLn $ "Read more: " ++ (show $ B.length bs) ++ "+" ++ (show $ B.length buffer) ++ "/" ++ (show maxLen)
    let buff = B.append buffer bs
    let decoder = decodeContent gen
    let decoded = decoder buff
    let decodedLen = B.length decoded
    if decodedLen >= maxLen
      then do
        putStrLn $ "Read result:" ++ (show (B.length decoded) ++ ":" ++ show (B.length buff)) ++ " " ++ (show decoded) ++ " -> " ++ (show buff)
        return decoded
      else do
        result <- readMoreBytes gen sock maxLen buff
        return result

putSessionPacket :: TrafficGenerator -> Session -> Plaintext -> Socket -> IO()
putSessionPacket gen session plaintext sock = do
    putStrLn $ "Session: " ++ (show session)
    let (Session (Keypair (PublicKey myPublic) _) _ (IV iv)) = session
--    let encoder = encodeContent gen
--    let encPub = encoder myPublic
--    let encIV = encoder iv
--    let encSession = B.append encPub encIV

    let packet = makePlainPacket plaintext
    let cipher = makeEncrypt session
    let (CipherDataPacket (CipherHeader (Ciphertext header)) (Ciphertext payload)) = encryptData cipher packet
--    let encHeader = encoder header
--    let encPayload = encoder payload
--    let encPacket = B.append encHeader encPayload -- 4 bytes, variable

--    let bytes = B.append encSession encPacket

    let sessionBytes = B.append myPublic iv
    let packetBytes = B.append header payload
    let bytes = B.append sessionBytes packetBytes

    putStrLn $ "Sending encoded bytes:"
--    putStrLn $ (show $ B.length myPublic) ++ ":" ++ (show $ B.length encPub) ++ " " ++ (show myPublic) ++ " -> " ++ (show encPub)
    putStrLn $ show myPublic
    putStrLn $ show iv
--    putStrLn $ (show $ B.length iv) ++ ":" ++ (show $ B.length encIV) ++ " " ++ (show iv) ++ " -> " ++ (show encIV)
--    putStrLn $ (show $ B.length header) ++ ":" ++ (show $ B.length encHeader) ++ " " ++ (show header) ++ " -> " ++ (show encHeader)
--    putStrLn $ (show $ B.length payload) ++ ":" ++ (show $ B.length encPayload) ++ " " ++ (show payload) ++ " -> " ++ (show encPayload)
--    putStrLn "==="
--    putStrLn $ show encIV
--    putStrLn $ show encSession
--    putStrLn $ show encPacket
    putStrLn "---------------------"
    sendBytes gen bytes sock

sendBytes :: TrafficGenerator -> B.ByteString -> Socket -> IO()
sendBytes gen msg sock = do
    let msgLength = B.length msg
    targetPacketLength <- generateLength gen

    putStrLn $ "Lengths: " ++ (show msgLength) ++ " " ++ (show targetPacketLength)

    let bs = case compare targetPacketLength msgLength of
                GT -> pad msg $ fromIntegral (targetPacketLength - msgLength)
                otherwise -> msg

    let (part, rest) = B.splitAt (fromIntegral targetPacketLength) bs

    putStrLn $ "Sending with target packet length of " ++ (show $ B.length part)
    appendFile "targetLenths.txt" $ show targetPacketLength ++ "\n"
    sendAll sock part

    if not $ B.null rest
        then sendBytes gen rest sock
        else return ()

pad :: B.ByteString -> Int -> B.ByteString
pad bs amount = B.append bs $ B.replicate amount 0
