{-# LANGUAGE RecordWildCards #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  System.RotatingLog
-- Copyright   :  Soostone Inc
-- License     :  BSD3
--
-- Maintainer  :  admin@soostone.com
-- Stability   :  experimental
--
-- Convenient logging to a disk-based log file with automatic file
-- rotation based on size.
----------------------------------------------------------------------------

module System.RotatingLog
  (

  -- * Core API
    RotatingLog
  , mkRotatingLog
  , rotatedWrite
  , rotatedWrite'
  , rotatedClose

  -- * Built-In Post-Rotate Actions
  , archiveFile

  ) where

-------------------------------------------------------------------------------
import           Control.Concurrent.MVar
import           Data.ByteString.Char8   (ByteString)
import qualified Data.ByteString.Char8   as B
import           Data.Time
import qualified Data.Time.Locale.Compat as LC
import           Data.Word
import           System.Directory
import           System.FilePath.Posix
import           System.IO
-------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | A size-limited rotating log.  Log filenames are of the format
-- prefix_timestamp.log.
data RotatingLog = RotatingLog
    { logInfo    :: MVar LogInfo
    , namePrefix :: String
    , sizeLimit  :: Word64
    , buffering  :: BufferMode
    , postAction :: FilePath -> IO ()
    }


data LogInfo = LogInfo
    { curHandle    :: Handle
    , bytesWritten :: !Word64
    }


curLogFileName :: String -> FilePath
curLogFileName = (++".log")


logFileName :: String -> UTCTime -> FilePath
logFileName pre t = concat
    [pre, "_", formatTime LC.defaultTimeLocale "%Y_%m_%d_%H_%M_%S%Q" t, ".log"]


------------------------------------------------------------------------------
-- | Creates a rotating log given a prefix and size limit in bytes.
mkRotatingLog
    :: String
    -- ^ A prefix for the written log files.
    -> Word64
    -- ^ A size limit in bytes.
    -> BufferMode
    -- ^ A buffering mode for output; we leave it to you to decide how
    -- often the file should be flushed.
    -> (FilePath -> IO ())
    -- ^ An action to be performed on the finished file following
    -- rotation. For example, you could give a callback that moves or
    -- ships the files somewhere else.
    -> IO RotatingLog
mkRotatingLog pre limit buf pa = do
    mvar <- newEmptyMVar
    let rl = RotatingLog mvar pre limit buf pa
    h <- openLogFile rl
    len <- hFileSize h
    putMVar mvar $ LogInfo h (fromIntegral len)
    return rl


-------------------------------------------------------------------------------
openLogFile :: RotatingLog -> IO Handle
openLogFile RotatingLog{..} = do
    let fp = curLogFileName namePrefix
    h <- openFile fp AppendMode
    hSetBuffering h buffering
    return h


------------------------------------------------------------------------------
-- | Like "rotatedWrite'", but doesn't need a UTCTime and obtains it
-- with a syscall.
rotatedWrite :: RotatingLog -> ByteString -> IO ()
rotatedWrite rlog bs = do
    t <- getCurrentTime
    rotatedWrite' rlog t bs


-------------------------------------------------------------------------------
-- | Close the underlying file handle and apply the post-action hook.
rotatedClose :: RotatingLog -> IO ()
rotatedClose r = do
    li <- readMVar (logInfo r)
    now <- getCurrentTime
    closeFile r li now


-------------------------------------------------------------------------------
-- | Close current file and apply post action.
closeFile :: RotatingLog -> LogInfo -> UTCTime -> IO ()
closeFile RotatingLog{..} LogInfo{..} now = do
    hClose curHandle
    let newFile = logFileName namePrefix now
    renameFile curFile newFile
    postAction newFile
  where
    curFile = curLogFileName namePrefix


------------------------------------------------------------------------------
-- | Writes ByteString to a rotating log file.  If this write would exceed the
-- size limit, then the file is closed and a new file opened.  This function
-- takes a UTCTime to allow a cached time to be used to avoid a system call.
--
-- Please note this function does NOT implicitly insert a newline at
-- the end of the string you provide. This is so that it can be used
-- to log non-textual streams such as binary serialized or compressed
-- content.
rotatedWrite' :: RotatingLog -> UTCTime -> ByteString -> IO ()
rotatedWrite' rl@RotatingLog{..} t bs = do
    modifyMVar_ logInfo $ \ li@LogInfo{..} -> do
        (h,b) <- if bytesWritten + len > sizeLimit
                   then do closeFile rl li t
                           h <- openLogFile rl
                           return (h, 0)
                   else return (curHandle, bytesWritten)
        B.hPutStr h bs
        return $! LogInfo h (len + b)
  where
    len = fromIntegral $ B.length bs


-------------------------------------------------------------------------------
-- | A built-in post-rotate action that moves the finished file to a
-- given archive location.
archiveFile
    :: FilePath
    -- ^ A target archive directory
    -> (FilePath -> IO ())
archiveFile archive fp =
    let (_, fn) = splitFileName fp
        target = archive </> fn
    in do
        createDirectoryIfMissing True archive
        renameFile fp target



