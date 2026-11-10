package quark

import (
	"bytes"
	"encoding/xml"
	"io"
	"strconv"
	"strings"
)

type partsPage struct {
	bucket    string
	receipts  []UploadPartReceipt
	truncated bool
	next      int
}

// parsePartsPage accepts only direct protocol fields, rejecting duplicate
// fields or a page that cannot advance within the negotiated part count.
func parsePartsPage(data []byte, session UploadSession, marker int) (partsPage, error) {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	fields := make(map[string]string)
	part := make(map[string]string)
	var stack []string
	var page partsPage
	var content strings.Builder
	previous, rootSeen := marker, false
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return partsPage{}, ErrInvalidResponse
		}
		switch t := token.(type) {
		case xml.Directive:
			return partsPage{}, ErrInvalidResponse
		case xml.StartElement:
			name := t.Name.Local
			stack = append(stack, name)
			switch len(stack) {
			case 1:
				if name != "ListPartsResult" || rootSeen {
					return partsPage{}, ErrInvalidResponse
				}
				rootSeen = true
			case 2:
				if name == "Part" {
					clear(part)
				}
			case 3:
				if stack[1] != "Part" {
					return partsPage{}, ErrInvalidResponse
				}
			default:
				return partsPage{}, ErrInvalidResponse
			}
			content.Reset()
		case xml.CharData:
			if len(stack) > 1 {
				content.Write(t)
			} else if len(bytes.TrimSpace(t)) != 0 {
				return partsPage{}, ErrInvalidResponse
			}
		case xml.EndElement:
			name := t.Name.Local
			switch len(stack) {
			case 3:
				if _, duplicate := part[name]; duplicate {
					return partsPage{}, ErrInvalidResponse
				}
				part[name] = content.String()
			case 2:
				if name == "Part" {
					number, okNumber := canonicalInt(part["PartNumber"])
					size, okSize := canonicalInt(part["Size"])
					etag := part["ETag"]
					if !okNumber || !okSize || number <= previous || number > session.PartCount() ||
						size != session.partLength(number) || !validHex(unquoteETag(etag), 32) {
						return partsPage{}, ErrInvalidResponse
					}
					page.receipts = append(page.receipts, UploadPartReceipt{UploadID: session.UploadID, Number: number, Size: size, ETag: etag})
					previous = number
				} else {
					if _, duplicate := fields[name]; duplicate {
						return partsPage{}, ErrInvalidResponse
					}
					fields[name] = content.String()
				}
			}
			stack = stack[:len(stack)-1]
			content.Reset()
		}
	}
	limit, err := strconv.Atoi(fields["MaxParts"])
	if !rootSeen || len(stack) != 0 || fields["Key"] != session.ObjectKey || fields["UploadId"] != session.UploadID ||
		!bucketPattern.MatchString(fields["Bucket"]) || fields["PartNumberMarker"] != strconv.Itoa(marker) ||
		err != nil || limit < 1 || limit > 1000 || len(page.receipts) > limit {
		return partsPage{}, ErrInvalidResponse
	}
	page.bucket, page.next = fields["Bucket"], previous
	switch fields["IsTruncated"] {
	case "true":
		next, err := strconv.Atoi(fields["NextPartNumberMarker"])
		if err != nil || next != previous || next <= marker {
			return partsPage{}, ErrInvalidResponse
		}
		page.truncated = true
	case "false":
	default:
		return partsPage{}, ErrInvalidResponse
	}
	return page, nil
}

func canonicalInt(value string) (int, bool) {
	integer, err := strconv.Atoi(value)
	return integer, err == nil && strconv.Itoa(integer) == value
}
