// Writes license notices for the pinned Go module graph into the app bundle.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	if len(os.Args) != 2 {
		panic("usage: notices OUTPUT")
	}
	command := exec.Command("go", "list", "-deps", "-json", ".")
	command.Env = append(os.Environ(), "GOOS=ios", "GOARCH=arm64", "CGO_ENABLED=1")
	data, err := command.Output()
	if err != nil {
		panic(err)
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	var text strings.Builder
	text.WriteString("Embedded Tailscale dependency licenses\n\n")
	seen := map[string]bool{}
	for {
		var pkg struct {
			Module *struct {
				Path, Version, Dir string
				Main               bool
			}
		}
		err = decoder.Decode(&pkg)
		if err == io.EOF {
			break
		}
		if err != nil {
			panic(err)
		}
		module := pkg.Module
		if module == nil || module.Main || seen[module.Path] {
			continue
		}
		seen[module.Path] = true
		if module.Dir == "" {
			panic("module not downloaded: " + module.Path)
		}
		fmt.Fprintf(&text, "\n===== %s %s =====\n", module.Path, module.Version)
		entries, err := os.ReadDir(module.Dir)
		if err != nil {
			panic(err)
		}
		found := false
		for _, entry := range entries {
			name := strings.ToUpper(entry.Name())
			if !entry.IsDir() && (strings.HasPrefix(name, "LICENSE") || strings.HasPrefix(name, "LICENCE") || strings.HasPrefix(name, "COPYING") || strings.HasPrefix(name, "NOTICE")) {
				b, e := os.ReadFile(filepath.Join(module.Dir, entry.Name()))
				if e != nil {
					panic(e)
				}
				fmt.Fprintf(&text, "\n--- %s ---\n%s\n", entry.Name(), b)
				found = true
			}
		}
		if !found {
			panic("review missing license notice: " + module.Path)
		}
	}
	goroot, err := exec.Command("go", "env", "GOROOT").Output()
	if err != nil {
		panic(err)
	}
	license, err := os.ReadFile(filepath.Join(strings.TrimSpace(string(goroot)), "LICENSE"))
	if os.IsNotExist(err) {
		license, err = os.ReadFile("/usr/share/licenses/go/LICENSE")
	}
	if err != nil {
		panic(err)
	}
	fmt.Fprintf(&text, "\n===== Go runtime =====\n%s\n", license)
	if err = os.WriteFile(os.Args[1], []byte(text.String()), 0644); err != nil {
		panic(err)
	}
}
