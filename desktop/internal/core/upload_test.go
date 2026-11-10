package core

import (
	"context"
	"crypto/md5"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

type uploadFixtureRecords struct {
	data    map[string][]byte
	secrets map[string][]byte
}

func (r uploadFixtureRecords) Read(key string, dst any) error {
	value, ok := r.data[key]
	if !ok {
		return fs.ErrNotExist
	}
	return json.Unmarshal(value, dst)
}

func (r uploadFixtureRecords) Write(key string, data any) error {
	value, err := json.Marshal(data)
	if err == nil {
		r.data[key] = value
	}
	return err
}

func (r uploadFixtureRecords) ReadCredential(key string) ([]byte, error) {
	value, ok := r.secrets[key]
	if !ok {
		return nil, fs.ErrNotExist
	}
	return value, nil
}

func (r uploadFixtureRecords) WriteCredential(key string, data []byte) error {
	r.secrets[key] = data
	return nil
}

func (r uploadFixtureRecords) RemoveCredential(key string) error {
	delete(r.secrets, key)
	return nil
}

type uploadRoundTrip func(*http.Request) (*http.Response, error)

func (f uploadRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestUploadFolderAndResumeOnlyReadback(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "资料")
	if err := os.MkdirAll(filepath.Join(root, "空目录"), 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "报告.txt")
	if err := os.WriteFile(file, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}

	var create, prepare, parts, merge, finish, readback atomic.Int32
	const fileName = "报告 (1).txt"
	const fileID = "file"
	transport := uploadRoundTrip(func(r *http.Request) (*http.Response, error) {
		raw := ""
		if r.Body != nil {
			data, err := io.ReadAll(r.Body)
			if err != nil {
				return nil, err
			}
			r.Body.Close()
			raw = string(data)
		}
		reply := func(text string) (*http.Response, error) {
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), ContentLength: int64(len(text)),
				Body: io.NopCloser(strings.NewReader(text)), Request: r}, nil
		}
		jsonReply := func(data string) (*http.Response, error) {
			return reply(`{"status":200,"code":0,"data":` + data + "}")
		}
		switch r.URL.Host {
		case "test.oss.quark.cn":
			if r.Method == http.MethodPost {
				merge.Add(1)
				return reply("<CompleteMultipartUploadResult/>")
			}
			parts.Add(1)
			number := r.URL.Query().Get("partNumber")
			if number == "1" && raw != "hel" || number == "2" && raw != "lo" || number != "1" && number != "2" {
				return nil, fmt.Errorf("incorrect part %s = %s", number, raw)
			}
			res, _ := reply("")
			res.Header.Set("ETag", fmt.Sprintf("%x", md5.Sum([]byte(raw))))
			return res, nil
		case "cdn.test":
			if n := readback.Add(1); n == 1 {
				return reply("HELLO")
			}
			return reply("hello")
		}
		switch r.URL.Path {
		case "/1/clouddrive/file/sort":
			parent := r.URL.Query().Get("pdir_fid")
			if parent == "0" {
				return jsonReply(`{"list":[]}`)
			}
			if parent != "parent" {
				return nil, fmt.Errorf("unexpected parent %s", parent)
			}
			rows := `{"fid":"existing","dir":false,"file_name":"报告.txt","pdir_fid":"parent","size":4}`
			if finish.Load() > 0 {
				rows += `,{"fid":"file","dir":false,"file_name":"` + fileName + `","pdir_fid":"parent","size":5}`
			}
			return jsonReply(`{"list":[` + rows + "]}")
		case "/1/clouddrive/file":
			var form struct {
				Name   string `json:"file_name"`
				Parent string `json:"pdir_fid"`
			}
			if err := json.Unmarshal([]byte(raw), &form); err != nil {
				return nil, err
			}
			create.Add(1)
			switch {
			case form.Name == "资料" && form.Parent == "0":
				return jsonReply(`{"fid":"parent"}`)
			case form.Name == "空目录" && form.Parent == "parent":
				return jsonReply(`{"fid":"empty"}`)
			default:
				return nil, fmt.Errorf("unexpected directory: %+v", form)
			}
		case "/1/clouddrive/file/upload/pre":
			var form struct {
				Name   string `json:"file_name"`
				Parent string `json:"pdir_fid"`
				Size   int64  `json:"size"`
			}
			if err := json.Unmarshal([]byte(raw), &form); err != nil {
				return nil, err
			}
			if form.Name != fileName || form.Parent != "parent" || form.Size != 5 {
				return nil, fmt.Errorf("wrong upload target: %+v", form)
			}
			prepare.Add(1)
			return reply(`{"status":200,"code":0,"metadata":{"part_size":3},"data":{"task_id":"task","fid":"file","upload_id":"upload","obj_key":"object","bucket":"test","upload_url":"https://oss.quark.cn","auth_info":"private-auth","callback":{}}}`)
		case "/1/clouddrive/file/update/hash":
			return jsonReply(`{"finish":false}`)
		case "/1/clouddrive/file/upload/auth":
			return jsonReply(`{"auth_key":"signed"}`)
		case "/1/clouddrive/file/upload/finish":
			finish.Add(1)
			return jsonReply("{}")
		case "/1/clouddrive/file/download":
			if raw != `{"fids":["file"]}` {
				return nil, fmt.Errorf("unexpected download identity %s", raw)
			}
			return jsonReply(`[{"fid":"file","size":5,"download_url":"https://cdn.test/file"}]`)
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	records := uploadFixtureRecords{make(map[string][]byte), make(map[string][]byte)}
	client := &http.Client{Transport: transport}
	req := UploadRequest{ID: "folder", Target: UploadTarget{Provider: "quark", AccountID: "fixture", FID: quark.RootFID},
		Sources: []platform.LocalReference{{Path: root}, {Path: file}}, ParallelParts: 2}
	providers := UploadProviders{AccountID: "fixture", Quark: quark.New(quark.Credential{}, client)}
	uploader := newUploader(records, client)
	result, err := uploader.Run(t.Context(), req, providers, nil)
	if !errors.Is(err, ErrUploadReadback) || len(result.Items) != 3 || result.Items[1].Error == "" || len(records.secrets) != 1 {
		t.Fatalf("initial result = %+v, err = %v, secrets = %d", result, err, len(records.secrets))
	}
	for _, raw := range records.data {
		if strings.Contains(string(raw), "private-auth") {
			t.Fatal("ordinary checkpoint contains upload authorization")
		}
	}
	// No local file is needed once the provider's exact receipt is durable.
	if err := os.Rename(file, file+".moved"); err != nil {
		t.Fatal(err)
	}
	result, err = newUploader(records, client).Run(t.Context(), req, providers, nil)
	if err != nil || len(result.Items) != 3 || result.Items[1].RemoteName != fileName || result.Items[1].FID != fileID ||
		result.Items[1].Error != "" || len(records.secrets) != 0 {
		t.Fatalf("resumed result = %+v, err = %v, secrets = %d", result, err, len(records.secrets))
	}
	counts := []int32{create.Load(), prepare.Load(), parts.Load(), merge.Load(), finish.Load(), readback.Load()}
	if !reflect.DeepEqual(counts, []int32{2, 1, 2, 1, 1, 2}) {
		t.Fatalf("network call counts = %v", counts)
	}
}

func TestUploadPersistsAnInFlightReceiptAfterCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	started := make(chan struct{})
	var saved []int
	err := sendUploadParts(ctx, []int{0, 1, 2}, 2, func(ctx context.Context, part int) (int, error) {
		switch part {
		case 0:
			close(started)
			<-ctx.Done()
			return part, nil
		case 1:
			<-started
			cancel()
			return 0, ctx.Err()
		default:
			return 0, fmt.Errorf("scheduled extra part after cancellation")
		}
	}, func(part int) error {
		saved = append(saved, part)
		return nil
	})
	if !errors.Is(err, context.Canceled) || !reflect.DeepEqual(saved, []int{0}) {
		t.Fatalf("error = %v, saved = %v", err, saved)
	}
}
