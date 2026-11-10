package download

import "os"

// A rooted link publishes atomically without replacing an existing file. Its
// original name remains available to identify it until the receipt is saved.
func publishExclusive(root *os.Root, from, to string) error { return root.Link(from, to) }

func publicationStamp(os.FileInfo) *fileStamp { return nil }

// Windows has no supported directory fsync. The temporary file and the
// versioned completion record are flushed separately.
func syncPublishDirectory(*os.Root) error { return nil }
