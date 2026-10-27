package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	defaultReadBytes = 16 << 20 // read_file default max_bytes
	maxReadBytes     = 48 << 20 // keeps the base64 response under 64 MiB
	maxDirEntries    = 10000
)

// cleanAbs validates a request path: required and absolute.
func cleanAbs(field, p string) (string, error) {
	if p == "" {
		return "", errf(codeBadRequest, "%q is required", field)
	}
	if !filepath.IsAbs(p) {
		return "", errf(codeBadRequest, "%s must be an absolute path: %q", field, p)
	}
	return filepath.Clean(p), nil
}

// ---- read_file ----

type readFileParams struct {
	Path     string `json:"path"`
	MaxBytes int64  `json:"max_bytes"`
	Offset   int64  `json:"offset"`
}

type readFileResult struct {
	Path      string `json:"path"`
	DataB64   string `json:"data_b64"`
	Size      int64  `json:"size"`
	Truncated bool   `json:"truncated"`
}

func opReadFile(ctx context.Context, s *Server, raw []byte) (any, error) {
	var p readFileParams
	if err := decodeParams(raw, &p); err != nil {
		return nil, err
	}
	path, err := cleanAbs("path", p.Path)
	if err != nil {
		return nil, err
	}
	if p.Offset < 0 || p.MaxBytes < 0 {
		return nil, errf(codeBadRequest, `"offset" and "max_bytes" must not be negative`)
	}
	max := p.MaxBytes
	if max == 0 {
		max = defaultReadBytes
	}
	if max > maxReadBytes {
		max = maxReadBytes
	}

	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		return nil, errf(codeBadRequest, "%s is a directory (use list_dir)", path)
	}
	if !st.Mode().IsRegular() {
		return nil, errf(codeBadRequest, "%s is not a regular file (%v)", path, st.Mode().Type())
	}
	if p.Offset > 0 {
		if _, err := f.Seek(p.Offset, io.SeekStart); err != nil {
			return nil, err
		}
	}
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	truncated := int64(len(data)) > max
	if truncated {
		data = data[:max]
	}
	size := st.Size()
	if end := p.Offset + int64(len(data)); !truncated && size < end {
		size = end // /proc and /sys files report size 0
	}
	return readFileResult{
		Path:      path,
		DataB64:   base64.StdEncoding.EncodeToString(data),
		Size:      size,
		Truncated: truncated,
	}, nil
}

// ---- write_file ----

type writeFileParams struct {
	Path    string          `json:"path"`
	DataB64 *string         `json:"data_b64"`
	Mode    json.RawMessage `json:"mode"`
	Mkdir   bool            `json:"mkdir"`
	Append  bool            `json:"append"`
}

type writeFileResult struct {
	Path    string `json:"path"`
	Written int    `json:"written"`
	Size    int64  `json:"size"`
}

func opWriteFile(ctx context.Context, s *Server, raw []byte) (any, error) {
	var p writeFileParams
	if err := decodeParams(raw, &p); err != nil {
		return nil, err
	}
	path, err := cleanAbs("path", p.Path)
	if err != nil {
		return nil, err
	}
	if p.DataB64 == nil {
		return nil, errf(codeBadRequest, `"data_b64" is required (use "" for an empty file)`)
	}
	data, err := decodeBase64(*p.DataB64)
	if err != nil {
		return nil, errf(codeBadRequest, "data_b64 is not valid base64: %v", err)
	}
	mode, hasMode, err := parseMode(p.Mode)
	if err != nil {
		return nil, err
	}

	dir := filepath.Dir(path)
	if p.Mkdir {
		if err := mkdirAllInherit(dir); err != nil {
			return nil, err
		}
	}
	_, statErr := os.Lstat(path)
	existed := statErr == nil

	flags := os.O_WRONLY | os.O_CREATE
	if p.Append {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
	}
	perm := fs.FileMode(0o644)
	if hasMode {
		perm = mode
	}
	f, err := os.OpenFile(path, flags, perm)
	if err != nil {
		return nil, err
	}
	n, werr := f.Write(data)
	cerr := f.Close()
	if werr != nil {
		return nil, werr
	}
	if cerr != nil {
		return nil, cerr
	}
	if hasMode {
		// OpenFile's perm only applies to new files and is masked by the umask.
		if err := os.Chmod(path, mode); err != nil {
			return nil, err
		}
	}
	if !existed {
		inheritOwner(path, dir)
	}
	res := writeFileResult{Path: path, Written: n}
	if st, err := os.Stat(path); err == nil {
		res.Size = st.Size()
	}
	return res, nil
}

func decodeBase64(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		if b2, err2 := base64.RawStdEncoding.DecodeString(strings.TrimRight(s, "=")); err2 == nil {
			return b2, nil
		}
	}
	return b, err
}

// parseMode accepts a JSON number (the numeric mode, e.g. 420 for 0644) or a
// string of octal digits ("0644", "644", "0o755"). Setuid/setgid/sticky bits
// (04000/02000/01000) are supported.
func parseMode(raw json.RawMessage) (fs.FileMode, bool, error) {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return 0, false, nil
	}
	var v uint64
	var err error
	if strings.HasPrefix(s, `"`) {
		var str string
		if err := json.Unmarshal(raw, &str); err != nil {
			return 0, false, errf(codeBadRequest, "invalid mode: %v", err)
		}
		str = strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(str), "0o"), "0O")
		v, err = strconv.ParseUint(str, 8, 32)
	} else {
		v, err = strconv.ParseUint(s, 10, 32)
	}
	if err != nil || v > 0o7777 {
		return 0, false, errf(codeBadRequest, "invalid mode %s: want an octal string like \"0644\" or a number <= 4095", s)
	}
	m := fs.FileMode(v & 0o777)
	if v&0o4000 != 0 {
		m |= fs.ModeSetuid
	}
	if v&0o2000 != 0 {
		m |= fs.ModeSetgid
	}
	if v&0o1000 != 0 {
		m |= fs.ModeSticky
	}
	return m, true, nil
}

// mkdirAllInherit creates dir and its missing parents (0755). When running as
// root the new directories get the owner of the closest existing ancestor, so
// a file written into /home/alice/new/dir stays usable by alice.
func mkdirAllInherit(dir string) error {
	anc := dir
	for {
		if _, err := os.Stat(anc); err == nil {
			break
		}
		parent := filepath.Dir(anc)
		if parent == anc {
			break
		}
		anc = parent
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if anc == dir || !isRoot() {
		return nil
	}
	st, err := os.Stat(anc)
	if err != nil {
		return nil
	}
	uid, gid, ok := fileOwner(st)
	if !ok || (uid == 0 && gid == 0) {
		return nil
	}
	for d := dir; d != anc && d != filepath.Dir(d); d = filepath.Dir(d) {
		os.Lchown(d, uid, gid)
	}
	return nil
}

// inheritOwner gives a newly created file the owner of its directory when
// the agent runs as root (best effort).
func inheritOwner(path, dir string) {
	if !isRoot() {
		return
	}
	st, err := os.Stat(dir)
	if err != nil {
		return
	}
	if uid, gid, ok := fileOwner(st); ok && (uid != 0 || gid != 0) {
		os.Lchown(path, uid, gid)
	}
}

// ---- list_dir ----

type listDirParams struct {
	Path string `json:"path"`
}

type dirEntry struct {
	Name      string `json:"name"`
	IsDir     bool   `json:"isDir"`
	IsSymlink bool   `json:"isSymlink"`
	Size      int64  `json:"size"`
	Mode      string `json:"mode"`
	Mtime     int64  `json:"mtime"`
}

type listDirResult struct {
	Path      string     `json:"path"`
	Entries   []dirEntry `json:"entries"`
	Truncated bool       `json:"truncated"`
}

func opListDir(ctx context.Context, s *Server, raw []byte) (any, error) {
	var p listDirParams
	if err := decodeParams(raw, &p); err != nil {
		return nil, err
	}
	path, err := cleanAbs("path", p.Path)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !st.IsDir() {
		return nil, errf(codeBadRequest, "%s is not a directory", path)
	}
	ents, err := os.ReadDir(path) // sorted by name
	if err != nil {
		return nil, err
	}
	res := listDirResult{Path: path, Entries: make([]dirEntry, 0, min(len(ents), maxDirEntries))}
	for _, e := range ents {
		if len(res.Entries) >= maxDirEntries {
			res.Truncated = true
			break
		}
		info, err := e.Info() // lstat
		if err != nil {
			continue // removed while listing
		}
		de := dirEntry{
			Name:  e.Name(),
			IsDir: info.IsDir(),
			Size:  info.Size(),
			Mode:  info.Mode().String(),
			Mtime: info.ModTime().Unix(),
		}
		if info.Mode()&fs.ModeSymlink != 0 {
			de.IsSymlink = true
			if target, err := os.Stat(filepath.Join(path, e.Name())); err == nil {
				de.IsDir, de.Size = target.IsDir(), target.Size()
			}
		}
		res.Entries = append(res.Entries, de)
	}
	return res, nil
}
