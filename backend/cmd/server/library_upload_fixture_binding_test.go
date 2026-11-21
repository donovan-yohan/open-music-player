package main

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"testing"
)

const fixtureBindingPipeEnv = "OMP_LIBRARY_UPLOAD_BINDING_PIPE"

// In the test executable only, inherit a one-shot pipe from the fixture
// provisioner. The grant is constructed from the provisioner's actual
// exclusive S3 bucket and owned listener, never from the child's environment.
func attachFixtureBucketGrant(t *testing.T, child *exec.Cmd, grant fixtureBucketGrant) func() {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal("open private fixture binding pipe")
	}
	if err := json.NewEncoder(writer).Encode(grant); err != nil {
		_ = writer.Close()
		_ = reader.Close()
		t.Fatal("write fixture binding")
	}
	if err := writer.Close(); err != nil {
		_ = reader.Close()
		t.Fatal("seal fixture binding")
	}
	child.ExtraFiles = []*os.File{reader}
	child.Env = append(child.Env, fixtureBindingPipeEnv+"=3")
	return func() { _ = reader.Close() }
}

func runPrivateLibraryChild(t *testing.T) {
	t.Helper()
	if os.Getenv(fixtureBindingPipeEnv) == "" {
		main() // Production entry point: no grant, even with all mode env set.
		return
	}
	if os.Getenv(fixtureBindingPipeEnv) != "3" {
		t.Fatal("invalid fixture binding descriptor")
	}
	file := os.NewFile(3, "fixture-binding-pipe")
	if file == nil {
		t.Fatal("missing fixture binding pipe")
	}
	info, err := file.Stat()
	if err != nil || info.Mode()&os.ModeNamedPipe == 0 {
		_ = file.Close()
		t.Fatal("fixture binding is not an inherited pipe")
	}
	const maxBindingBytes = 256
	raw, err := io.ReadAll(io.LimitReader(file, maxBindingBytes+1))
	_ = file.Close()
	var grant fixtureBucketGrant
	if err != nil || len(raw) > maxBindingBytes || json.Unmarshal(raw, &grant) != nil || grant.Endpoint == "" || grant.Bucket == "" {
		t.Fatal("invalid fixture binding payload")
	}
	os.Exit(runServerWithPrivateLibraryFixture(&privateLibraryFixtureBinding{endpoint: grant.Endpoint, bucket: grant.Bucket}))
}
