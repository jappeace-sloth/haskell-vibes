-- | Naming external-process spawns in the exception context.
--
-- 'System.Process.Typed.readProcess' spawns through @posix_spawnp@. When that
-- fails, for a missing binary or a @\/bin@ symlink left dangling by a nix
-- garbage-collection, the exception is a bare
-- @git: startProcess: posix_spawnp: does not exist@ that says nothing about
-- which of the gate's spawns raised it. Wrapping every spawn in 'annotateSpawn'
-- attaches its command, and (via 'checkpoint'\'s 'HasCallStack') the call site,
-- to the exception with @annotated-exception@, so an uncaught crash, or a
-- 'Control.Exception.displayException' of a caught one, names the spawn.
module Gate.SpawnAnnotation
  ( ProcessCallSite(..)
  , annotateSpawn
  ) where

import Control.Exception.Annotated (Annotation (Annotation), checkpoint)
import GHC.Stack (HasCallStack)

-- | The command a process spawn was for. Its 'Show' is the message the
-- annotation renders, so a crash reads as a sentence rather than a constructor.
newtype ProcessCallSite = ProcessCallSite String

instance Show ProcessCallSite where
  show (ProcessCallSite command) = "while spawning: " <> command

-- | Run a process spawn with its command, and the caller's source location,
-- attached to any exception it raises. The action is otherwise unchanged; this
-- only decorates failures.
annotateSpawn :: HasCallStack => String -> IO a -> IO a
annotateSpawn command = checkpoint (Annotation (ProcessCallSite command))
