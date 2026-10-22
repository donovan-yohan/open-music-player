package jam

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestJamGuestJavaScriptContracts(t *testing.T) {
	node, e := exec.LookPath("node")
	if e != nil {
		t.Skip("node required")
	}
	dir, e := os.Getwd()
	if e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command(node, "--test", filepath.Join(dir, "web", "app.test.cjs"))
	out, e := cmd.CombinedOutput()
	if e != nil {
		t.Fatalf("JS contract: %v\n%s", e, out)
	}
	t.Log(string(out))
}
