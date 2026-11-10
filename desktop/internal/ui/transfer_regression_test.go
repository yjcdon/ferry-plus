package ui

import (
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func TestTransferSearchFindsBatchFiles(t *testing.T) {
	job := app.TransferJob{Title: "旅行资料", AccountName: "我的账号", Items: []app.TransferItem{
		{RelativePath: "旅行资料/攻略/PLAN.PDF"}, {RelativePath: "旅行资料/车票.png"},
	}}
	for _, query := range []string{"", "旅行", "我的账号", "plan.pdf", "车票"} {
		if !matchesTransferSearch(job, query) {
			t.Errorf("batch search did not match %q", query)
		}
	}
	if matchesTransferSearch(job, "不存在") {
		t.Fatal("unrelated filename matched")
	}
}
