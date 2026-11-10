package platform

import (
	"fmt"
	"strings"
)

func rememberLocalItem(path string) (LocalReference, error) {
	return LocalReference{Path: path}, nil
}

func openLocalItem(ref LocalReference) (*LocalAccess, error) {
	return &LocalAccess{Reference: ref}, nil
}

func validateLocalNames(path string) error {
	for _, name := range strings.Split(path, "/") {
		stem, _, _ := strings.Cut(name, ".")
		stem = strings.ToUpper(strings.TrimRight(stem, " "))
		if strings.HasSuffix(name, ".") || strings.HasSuffix(name, " ") ||
			strings.ContainsAny(name, `<>:"\|?*`) || strings.IndexFunc(name, func(r rune) bool { return r < 32 }) >= 0 ||
			isWindowsDeviceName(stem) {
			return fmt.Errorf("Windows 无法使用此文件名 %q", name)
		}
	}
	return nil
}

func isWindowsDeviceName(stem string) bool {
	switch stem {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$":
		return true
	}
	if strings.HasPrefix(stem, "COM") || strings.HasPrefix(stem, "LPT") {
		switch stem[3:] {
		case "1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³":
			return true
		}
	}
	return false
}
