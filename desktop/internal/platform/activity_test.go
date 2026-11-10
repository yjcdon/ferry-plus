package platform

import "testing"

func TestTransfersShareOnePowerAssertion(t *testing.T) {
	var group sharedActivity
	var starts, ends int
	begin := func() (func(), error) {
		starts++
		return func() { ends++ }, nil
	}
	first, err := group.acquire(begin)
	if err != nil {
		t.Fatal(err)
	}
	second, err := group.acquire(begin)
	if err != nil {
		t.Fatal(err)
	}
	if starts != 1 || ends != 0 {
		t.Fatalf("两个活动应共用一个声明，实际取得 %d 次、释放 %d 次", starts, ends)
	}
	first()
	first()
	if ends != 0 {
		t.Fatal("另一个活动仍在执行")
	}
	second()
	if ends != 1 {
		t.Fatal("最后一个活动结束后应释放声明")
	}
	third, err := group.acquire(begin)
	if err != nil {
		t.Fatal(err)
	}
	third()
	if starts != 2 || ends != 2 {
		t.Fatalf("新一轮传输应重新取得并释放声明，实际取得 %d 次、释放 %d 次", starts, ends)
	}
}
