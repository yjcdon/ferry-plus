package quark

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestMultipartUsesNegotiatedSizesAndCanonicalSigning(t *testing.T) {
	const bucketHost = "demo.oss.quark.cn"
	const objectKey = "directory/测试.txt"
	const uploadID = "upload+/="
	preparationResponse := fixtureResponse(http.StatusOK, `{"status":200,"code":"0","data":{"task_id":"task","fid":"file","upload_id":"`+
		uploadID+`","obj_key":"`+objectKey+`","bucket":"demo","upload_url":"http://oss.quark.cn",
		"auth_info":"opaque","callback":{"callbackUrl":"https://drive-pc.quark.cn/callback"}},"metadata":{"part_size":3}}`)
	authRequests, uploadRequests, listRequests, completeRequests, finishRequests := 0, 0, 0, 0, 0
	var lastMeta string
	client := New(Credential{Cookies: []Cookie{{Name: "session", Value: "private", Domain: ".quark.cn", Path: "/"}}},
		&http.Client{Transport: fixtureTransport(func(request *http.Request) *http.Response {
			if request.URL.Host == bucketHost {
				if request.URL.Scheme != "https" || request.URL.Path != "/"+objectKey || request.URL.Query().Get("uploadId") != uploadID ||
					strings.Contains(request.URL.RawQuery, "+") || request.Header.Get("Cookie") != "" ||
					request.Header.Get("Authorization") != "signed" || request.Header.Get("x-oss-user-agent") != ossAgent {
					t.Fatalf("unexpected OSS request: %s %v", request.URL, request.Header)
				}
				var body []byte
				if request.Body != nil {
					var err error
					body, err = io.ReadAll(request.Body)
					if err != nil {
						t.Fatal(err)
					}
				}
				date := request.Header.Get("x-oss-date")
				var expectedMeta string
				var response *http.Response
				switch request.Method {
				case http.MethodPut:
					uploadRequests++
					number := request.URL.Query().Get("partNumber")
					if number != fmt.Sprint(uploadRequests) || string(body) != []string{"abc", "de"}[uploadRequests-1] {
						t.Fatalf("part %s body %q", number, body)
					}
					expectedMeta = fmt.Sprintf("PUT\n\napplication/octet-stream\n%s\nx-oss-date:%s\nx-oss-user-agent:%s\n/demo/%s?partNumber=%s&uploadId=%s", date, date, ossAgent, objectKey, number, uploadID)
					response = fixtureResponse(http.StatusOK, "")
					digest := md5.Sum(body)
					response.Header.Set("ETag", fmt.Sprintf("%q", hex.EncodeToString(digest[:])))
				case http.MethodGet:
					listRequests++
					marker := request.URL.Query().Get("part-number-marker")
					if request.URL.Query().Get("max-parts") != "1000" || (listRequests == 1 && marker != "") || (listRequests == 2 && marker != "1") {
						t.Fatalf("unexpected list query: %v", request.URL.Query())
					}
					expectedMeta = fmt.Sprintf("GET\n\n\n%s\nx-oss-date:%s\nx-oss-user-agent:%s\n/demo/%s?uploadId=%s", date, date, ossAgent, objectKey, uploadID)
					response = fixtureResponse(http.StatusOK, fmt.Sprintf(`<ListPartsResult><Bucket>actual-bucket</Bucket><Key>%s</Key><UploadId>%s</UploadId><PartNumberMarker>%d</PartNumberMarker><MaxParts>1000</MaxParts><IsTruncated>%t</IsTruncated><NextPartNumberMarker>%d</NextPartNumberMarker><Part><PartNumber>%d</PartNumber><ETag>"%x"</ETag><Size>%d</Size></Part></ListPartsResult>`,
						objectKey, uploadID, listRequests-1, listRequests == 1, listRequests, listRequests,
						md5.Sum([]byte([]string{"abc", "de"}[listRequests-1])), []int{3, 2}[listRequests-1]))
				case http.MethodPost:
					completeRequests++
					if !strings.HasPrefix(string(body), `<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUpload><Part><PartNumber>1</PartNumber>`) ||
						!strings.Contains(string(body), "<Part><PartNumber>2</PartNumber>") {
						t.Fatalf("unexpected merge document: %q", body)
					}
					digest := md5.Sum(body)
					bodyMD5 := base64.StdEncoding.EncodeToString(digest[:])
					callback := base64.StdEncoding.EncodeToString([]byte(`{"callbackUrl":"https://drive-pc.quark.cn/callback"}`))
					if request.Header.Get("Content-MD5") != bodyMD5 || request.Header.Get("x-oss-callback") != callback {
						t.Fatalf("unexpected merge headers: %v", request.Header)
					}
					expectedMeta = fmt.Sprintf("POST\n%s\napplication/xml\n%s\nx-oss-callback:%s\nx-oss-date:%s\nx-oss-user-agent:%s\n/demo/%s?uploadId=%s", bodyMD5, date, callback, date, ossAgent, objectKey, uploadID)
					response = fixtureResponse(http.StatusOK, "<CompleteMultipartUploadResult/>")
				default:
					t.Fatalf("unexpected method %s", request.Method)
				}
				if lastMeta != expectedMeta {
					t.Fatalf("auth_meta = %q\nwant = %q", lastMeta, expectedMeta)
				}
				return response
			}
			if request.URL.Host != pcHost || request.Header.Get("Cookie") != "session=private" {
				t.Fatalf("unexpected drive request: %v", request.URL)
			}
			body := fixtureBody(t, request)
			switch request.URL.Path {
			case "/1/clouddrive/file/upload/pre":
				if body["l_created_at"] != float64(1234) || body["l_updated_at"] != float64(4321) || body["size"] != float64(5) ||
					body["pdir_fid"] != "0" || body["ccp_hash_update"] != true || body["format_type"] != "application/octet-stream" {
					t.Fatalf("prepare body = %v", body)
				}
				return preparationResponse
			case "/1/clouddrive/file/update/hash":
				if body["md5"] != strings.Repeat("a", 32) || body["sha1"] != strings.Repeat("b", 40) {
					t.Fatalf("hash body = %v", body)
				}
				return fixtureSuccess(`{"finish":false}`)
			case "/1/clouddrive/file/upload/auth":
				authRequests++
				if body["auth_info"] != "opaque" || body["task_id"] != "task" {
					t.Fatalf("authorization body = %v", body)
				}
				lastMeta, _ = body["auth_meta"].(string)
				return fixtureSuccess(`{"auth_key":"signed"}`)
			case "/1/clouddrive/file/upload/finish":
				finishRequests++
				if body["obj_key"] != objectKey || body["task_id"] != "task" {
					t.Fatalf("finish body = %v", body)
				}
				return fixtureSuccess("{}")
			default:
				t.Fatalf("unexpected drive endpoint %s", request.URL)
				return nil
			}
		})})
	ctx := t.Context()
	preparation, err := client.PrepareUpload(ctx, "测试.txt", RootFID, 5, time.UnixMilli(1234), time.UnixMilli(4321))
	if err != nil || preparation.Session.PartCount() != 2 || preparation.Session.PartSize != 3 {
		t.Fatalf("preparation=%+v err=%v", preparation.Session, err)
	}
	rawSession, err := json.Marshal(preparation.Session)
	if err != nil || strings.Contains(string(rawSession), "opaque") {
		t.Fatalf("bad persisted session: %s, %v", rawSession, err)
	}
	var session UploadSession
	if err := json.Unmarshal(rawSession, &session); err != nil || session != preparation.Session {
		t.Fatalf("session restore: %v", err)
	}
	secret, err := preparation.Authorization.Encoded()
	if err != nil {
		t.Fatal(err)
	}
	auth, err := DecodeUploadAuthorization(secret)
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.NegotiateUploadHash(ctx, session, strings.Repeat("A", 32), strings.Repeat("B", 40))
	if err != nil || result != RequiresTransfer {
		t.Fatalf("hash result=%v err=%v", result, err)
	}
	for number, part := range []string{"abc", "de"} {
		if _, err := client.UploadPart(ctx, session, auth, number+1, []byte(part)); err != nil {
			t.Fatal(err)
		}
	}
	receipts, err := client.ListUploadParts(ctx, session, auth)
	if err != nil || len(receipts) != 2 || receipts[1].Size != 2 {
		t.Fatalf("parts=%+v err=%v", receipts, err)
	}
	if err := client.CompleteUploadParts(ctx, session, auth, []UploadPartReceipt{receipts[1], receipts[0]}); err != nil {
		t.Fatal(err)
	}
	if err := client.FinishUpload(ctx, session); err != nil {
		t.Fatal(err)
	}
	if authRequests != 5 || uploadRequests != 2 || listRequests != 2 || completeRequests != 1 || finishRequests != 1 {
		t.Fatalf("requests auth=%d put=%d get=%d complete=%d finish=%d", authRequests, uploadRequests, listRequests, completeRequests, finishRequests)
	}
}

func TestPartsPageRejectsDuplicateIdentityAndWrongLength(t *testing.T) {
	session := UploadSession{UploadID: "upload", ObjectKey: "key", Size: 3, PartSize: 3}
	const valid = `<ListPartsResult><Bucket>bucket</Bucket><Key>key</Key><UploadId>upload</UploadId><PartNumberMarker>0</PartNumberMarker><MaxParts>1000</MaxParts><IsTruncated>false</IsTruncated><Part><PartNumber>1</PartNumber><ETag>"900150983cd24fb0d6963f7d28e17f72"</ETag><Size>3</Size></Part></ListPartsResult>`
	for _, input := range []string{
		strings.Replace(valid, "<Key>key</Key>", "<Key>key</Key><Key>key</Key>", 1),
		strings.Replace(valid, "<UploadId>upload</UploadId>", "<UploadId>other</UploadId>", 1),
		strings.Replace(valid, "<Size>3</Size>", "<Size>2</Size>", 1),
	} {
		if _, err := parsePartsPage([]byte(input), session, 0); !errors.Is(err, ErrInvalidResponse) {
			t.Fatalf("malformed listing was accepted: %v", err)
		}
	}
}
