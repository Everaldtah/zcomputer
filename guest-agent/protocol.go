package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
)

// protocolVersion is bumped on incompatible wire changes. Additive changes
// (new ops, new optional fields) keep the number.
const protocolVersion = 1

// Error codes carried in the "code" field of a failed response. See PROTOCOL.md.
const (
	codeBadRequest  = "bad_request"       // malformed JSON, missing/invalid fields
	codeUnknownOp   = "unknown_op"        // op not implemented by this agent
	codeTooLarge    = "too_large"         // request line longer than the limit
	codeNotFound    = "not_found"         // file or directory does not exist
	codePermission  = "permission_denied" // EACCES / EPERM
	codeUnavailable = "unavailable"       // no desktop session, no tool installed, unsupported here
	codeFailed      = "failed"            // the operation ran and failed (tool exit != 0, I/O error, ...)
	codeInternal    = "internal"          // bug in the agent (panic)
)

// opError is an error with a protocol error code.
type opError struct {
	code string
	msg  string
}

func (e *opError) Error() string { return e.msg }

func errf(code, format string, args ...any) *opError {
	return &opError{code: code, msg: fmt.Sprintf(format, args...)}
}

// classify maps any error to a protocol error code and message.
func classify(err error) (code, msg string) {
	var oe *opError
	switch {
	case errors.As(err, &oe):
		return oe.code, oe.msg
	case errors.Is(err, fs.ErrNotExist):
		return codeNotFound, err.Error()
	case errors.Is(err, fs.ErrPermission):
		return codePermission, err.Error()
	default:
		return codeFailed, err.Error()
	}
}

// requestHeader is the part of every request the dispatcher needs; op handlers
// decode the full line again into their own parameter struct.
type requestHeader struct {
	ID json.RawMessage `json:"id"`
	Op string          `json:"op"`
}

// parseID returns the request id. Absent or null ids become "".
func parseID(raw json.RawMessage) (string, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return "", nil
	}
	var id string
	if err := json.Unmarshal(raw, &id); err != nil {
		return "", errf(codeBadRequest, "id must be a JSON string")
	}
	return id, nil
}

// marshalNoEscape is json.Marshal without HTML escaping (keeps <, >, & in
// command output readable) and without the trailing newline.
func marshalNoEscape(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// encodeSuccess builds {"id":..,"ok":true,<fields of result>} on one line.
// result must marshal to a JSON object (a struct or a map) or be nil.
func encodeSuccess(id string, result any) []byte {
	idJSON, _ := marshalNoEscape(id)
	out := make([]byte, 0, 64)
	out = append(out, `{"id":`...)
	out = append(out, idJSON...)
	out = append(out, `,"ok":true`...)
	if result != nil {
		body, err := marshalNoEscape(result)
		if err != nil || len(body) < 2 || body[0] != '{' {
			return encodeError(id, errf(codeInternal, "cannot encode result: %v", err))
		}
		if inner := bytes.TrimSpace(body[1 : len(body)-1]); len(inner) > 0 {
			out = append(out, ',')
			out = append(out, inner...)
		}
	}
	return append(out, '}')
}

// encodeError builds {"id":..,"ok":false,"error":..,"code":..} on one line.
func encodeError(id string, err error) []byte {
	code, msg := classify(err)
	b, _ := marshalNoEscape(struct {
		ID    string `json:"id"`
		OK    bool   `json:"ok"`
		Error string `json:"error"`
		Code  string `json:"code"`
	}{id, false, msg, code})
	return b
}

// decodeParams decodes the full request line into an op's parameter struct.
func decodeParams(raw []byte, v any) error {
	if err := json.Unmarshal(raw, v); err != nil {
		return errf(codeBadRequest, "invalid parameters: %v", err)
	}
	return nil
}
