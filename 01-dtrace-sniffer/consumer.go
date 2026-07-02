// Package axsniff parses the tab-separated record stream emitted by
// sniff.d (running against iPhone Mirroring) and builds an in-memory
// model of the iOS accessibility tree as Mirror translates it.
//
// Records (all tab-separated, prefix in column 0):
//
//	AX   self attr ret b0..b7         normal return; first 64 bytes of obj
//	AXN  self attr                    return was nil
//	AXT  self attr tagged             tagged-pointer return (raw)
//	AXS  self attr ret str            string deref of CFConstant return
//	AXET self attrTagged              entry where attr name was tagged ptr
//	CV   self attr ret b0..b3         _convertTranslatorResponse return
//	CVS  self attr ret str            string deref of CV return
//	CVT  self attr tagged             tagged CV return
//	ROL  self ret str                 accessibilityRole return
//	LBL  self ret str                 accessibilityLabel return
//	PAR  self ret                     accessibilityParent return
//	AXF  self                         accessibilityFrame entry (no rect)
//
// Anything else is dtrace diagnostic output and is dropped.
package axsniff

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Element is the rolling view of a single AXPMacPlatformElement, keyed by
// its self pointer in Mirror's heap. Fields are filled in as records
// arrive — empty values just mean "not seen yet this session".
type Element struct {
	Self     uint64            `json:"self"`
	Role     string            `json:"role,omitempty"`
	Label    string            `json:"label,omitempty"`
	Parent   uint64            `json:"parent,omitempty"`
	Children []uint64          `json:"children,omitempty"`
	Attrs    map[string]string `json:"attrs,omitempty"` // attr -> last string value
	LastSeen time.Time         `json:"last_seen"`
	Hits     int               `json:"hits"`
}

// Tree holds every element the sniffer has observed in the live process.
// Safe for concurrent reads via Snapshot; mutations are funneled through Run.
type Tree struct {
	mu       sync.RWMutex
	elements map[uint64]*Element
}

func NewTree() *Tree { return &Tree{elements: make(map[uint64]*Element)} }

func (t *Tree) get(self uint64) *Element {
	e := t.elements[self]
	if e == nil {
		e = &Element{Self: self, Attrs: make(map[string]string)}
		t.elements[self] = e
	}
	e.LastSeen = time.Now()
	e.Hits++
	return e
}

// Snapshot returns a JSON-marshalable copy of every element currently known.
func (t *Tree) Snapshot() []*Element {
	t.mu.RLock()
	defer t.mu.RUnlock()
	out := make([]*Element, 0, len(t.elements))
	for _, e := range t.elements {
		ec := *e
		ec.Children = append([]uint64(nil), e.Children...)
		ec.Attrs = make(map[string]string, len(e.Attrs))
		for k, v := range e.Attrs {
			ec.Attrs[k] = v
		}
		out = append(out, &ec)
	}
	return out
}

// SnapshotJSON returns the snapshot encoded as a JSON array.
func (t *Tree) SnapshotJSON() ([]byte, error) {
	return json.Marshal(t.Snapshot())
}

// Roots returns elements that are referenced as a parent by another element
// but never appeared as a child of anything. Useful for picking app/window
// nodes when building a tree view.
func (t *Tree) Roots() []*Element {
	t.mu.RLock()
	defer t.mu.RUnlock()
	hasParent := make(map[uint64]bool)
	for _, e := range t.elements {
		if e.Parent != 0 {
			hasParent[e.Self] = true
		}
	}
	var roots []*Element
	for _, e := range t.elements {
		if !hasParent[e.Self] {
			roots = append(roots, e)
		}
	}
	return roots
}

// Stats returns counts for monitoring the live stream.
type Stats struct {
	Records  int
	Elements int
	Roles    map[string]int
	Labels   int
	Errors   int
}

func (t *Tree) Stats() Stats {
	t.mu.RLock()
	defer t.mu.RUnlock()
	s := Stats{Elements: len(t.elements), Roles: map[string]int{}}
	for _, e := range t.elements {
		if e.Role != "" {
			s.Roles[e.Role]++
		}
		if e.Label != "" {
			s.Labels++
		}
	}
	return s
}

// Run consumes records from r and folds them into the tree until r closes
// or ctx is cancelled. Returns the number of records processed and io error
// (nil on EOF).
func (t *Tree) Run(ctx context.Context, r io.Reader) (int, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	count := 0
	for sc.Scan() {
		select {
		case <-ctx.Done():
			return count, ctx.Err()
		default:
		}
		line := sc.Text()
		if line == "" {
			continue
		}
		t.mu.Lock()
		t.consume(line)
		t.mu.Unlock()
		count++
	}
	return count, sc.Err()
}

// parseHex parses a hex pointer that may or may not be prefixed with 0x.
func parseHex(s string) (uint64, bool) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "0x")
	v, err := strconv.ParseUint(s, 16, 64)
	return v, err == nil
}

func (t *Tree) consume(line string) {
	f := strings.Split(line, "\t")
	if len(f) < 2 {
		return
	}
	switch f[0] {
	case "AX":
		// AX self attr ret b0..b7
		if len(f) < 4 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		e := t.get(self)
		attr := f[2]
		// Cache role/label seen via the generic attr API too.
		if len(f) >= 5 {
			// We don't have the string value here unless AXS comes later;
			// just remember the attribute was queried.
			if _, has := e.Attrs[attr]; !has {
				e.Attrs[attr] = ""
			}
		}
	case "AXN":
		if len(f) < 3 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		t.get(self) // touch
	case "AXT":
		if len(f) < 4 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		t.get(self).Attrs[f[2]] = "<tagged:" + f[3] + ">"
	case "AXS":
		if len(f) < 5 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		e := t.get(self)
		attr, val := f[2], f[4]
		e.Attrs[attr] = val
		assignText(e, attr, val)
	case "AXET":
		// entry only — nothing to record
	case "CV":
		if len(f) < 4 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		t.get(self) // touch
	case "CVS":
		if len(f) < 5 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		e := t.get(self)
		attr, val := f[2], f[4]
		e.Attrs[attr] = val
		assignText(e, attr, val)
	case "CVT":
		if len(f) < 4 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		t.get(self).Attrs[f[2]] = "<tagged:" + f[3] + ">"
	case "ROL":
		// ROL self ret str
		if len(f) < 4 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		t.get(self).Role = f[3]
	case "LBL":
		if len(f) < 4 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		t.get(self).Label = f[3]
	case "LBLT":
		// LBLT self taggedPtr — short NSTaggedPointerString
		if len(f) < 3 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		ptr, ok := parseHex(f[2])
		if !ok {
			return
		}
		if s := decodeTaggedString(ptr); s != "" {
			e := t.get(self)
			if len(s) > len(e.Label) {
				e.Label = s
			}
		}
	case "ROLT":
		if len(f) < 3 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		ptr, ok := parseHex(f[2])
		if !ok {
			return
		}
		if s := decodeTaggedString(ptr); s != "" {
			t.get(self).Role = s
		}
	case "PAR":
		if len(f) < 3 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		par, ok := parseHex(f[2])
		if !ok {
			return
		}
		e := t.get(self)
		e.Parent = par
		// Maintain reverse index: parent's children list.
		p := t.get(par)
		for _, c := range p.Children {
			if c == self {
				return
			}
		}
		p.Children = append(p.Children, self)
	case "AXF":
		if len(f) < 2 {
			return
		}
		self, ok := parseHex(f[1])
		if !ok {
			return
		}
		t.get(self) // touch
	}
}

// Sniffer spawns `sudo dtrace -p <pid> -s <script>` and feeds its stdout
// into a Tree. Caller must hold sudo creds (consumer cannot prompt).
type Sniffer struct {
	Pid    int
	Script string // path to sniff.d
	cmd    *exec.Cmd
	Tree   *Tree
}

func NewSniffer(pid int, scriptPath string) *Sniffer {
	return &Sniffer{Pid: pid, Script: scriptPath, Tree: NewTree()}
}

// Start launches dtrace and returns once stdout is being consumed in a
// background goroutine. errc receives the eventual exit error (nil on
// clean stop).
func (s *Sniffer) Start(ctx context.Context) (errc <-chan error, err error) {
	s.cmd = exec.CommandContext(ctx, "sudo", "-n", "dtrace",
		"-p", strconv.Itoa(s.Pid), "-s", s.Script)
	stdout, err := s.cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	s.cmd.Stderr = io.Discard // dtrace gripes about copyin; we don't care
	if err := s.cmd.Start(); err != nil {
		return nil, err
	}
	ch := make(chan error, 1)
	go func() {
		_, _ = s.Tree.Run(ctx, stdout)
		ch <- s.cmd.Wait()
	}()
	return ch, nil
}

// Stop sends SIGINT to dtrace.
func (s *Sniffer) Stop() error {
	if s.cmd == nil || s.cmd.Process == nil {
		return nil
	}
	return s.cmd.Process.Signal(interruptSignal)
}

// FormatTree renders a human-readable indented view of the snapshot,
// useful for debugging from the CLI.
func FormatTree(t *Tree) string {
	roots := t.Roots()
	var b strings.Builder
	t.mu.RLock()
	defer t.mu.RUnlock()
	var walk func(e *Element, depth int)
	seen := make(map[uint64]bool)
	walk = func(e *Element, depth int) {
		if seen[e.Self] || depth > 12 {
			return
		}
		seen[e.Self] = true
		fmt.Fprintf(&b, "%s%s %q (0x%x)\n",
			strings.Repeat("  ", depth),
			nz(e.Role, "?"), e.Label, e.Self)
		for _, c := range e.Children {
			if ce, ok := t.elements[c]; ok {
				walk(ce, depth+1)
			}
		}
	}
	for _, r := range roots {
		walk(r, 0)
	}
	return b.String()
}

func nz(s, alt string) string {
	if s == "" {
		return alt
	}
	return s
}

// assignText folds a string attribute value into Element role/label fields.
// When attr is unknown ("<tagged>"), uses content heuristics: a value that
// looks like an iOS role name fills Role; anything else printable becomes
// the Label (preferring longer, more descriptive values).
func assignText(e *Element, attr, val string) {
	if val == "" {
		return
	}
	switch attr {
	case "AXRole", "AXSubrole":
		if isPrintable(val) {
			e.Role = val
		}
		return
	case "AXLabel", "AXDescription", "AXTitle", "AXValue", "AXHelp":
		if isPrintable(val) && len(val) > len(e.Label) {
			e.Label = val
		}
		return
	}
	// attr unknown (tagged CFString). Heuristics:
	if !isPrintable(val) {
		return
	}
	if looksLikeRole(val) {
		if e.Role == "" {
			e.Role = val
		}
		return
	}
	if len(val) > len(e.Label) {
		e.Label = val
	}
}

func isPrintable(s string) bool {
	if len(s) == 0 {
		return false
	}
	hasLetter := false
	for _, r := range s {
		if r < 0x20 || r >= 0x7f {
			return false
		}
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
			hasLetter = true
		}
	}
	return hasLetter
}

// decodeTaggedString decodes an arm64 macOS NSTaggedPointerString into UTF-8.
// Format (Apple, undocumented but stable since iOS 7 / macOS 10.10):
//
//	bit 63       = 1 (always set on tagged ptr)
//	bits 60..62  = tag class (0b111 / 7 = NSTaggedPointerString)
//	bits 56..59  = length (0..15)
//	bits 0..55   = payload, packed depending on length:
//	   len <= 7  : 8-bit ASCII per char, bytes 0..len-1
//	   len 8..9  : 6-bit packed (alphabet "eilotrm.apdnsIc ufkMShjTRxgC4013bDNvwyUL2O856P-V%7+FKEWB9ZHYGQJ#zQX_&!?")
//	   len 10..11: 5-bit packed (alphabet "eilotrm.apdnsIc ufkMShjTRxgC4013")
//	for the most common short labels (Mail, Photos, Camera) the 8-bit path
//	is what you'll hit.
func decodeTaggedString(p uint64) string {
	if p&(1<<63) == 0 {
		return ""
	}
	tagClass := (p >> 60) & 0x7
	if tagClass != 7 {
		return ""
	}
	length := int((p >> 56) & 0xf)
	if length == 0 || length > 15 {
		return ""
	}
	payload := p & 0x00ffffffffffffff
	switch {
	case length <= 7:
		buf := make([]byte, length)
		for i := 0; i < length; i++ {
			buf[i] = byte(payload >> (uint(i) * 8))
		}
		for _, b := range buf {
			if b == 0 || b >= 0x80 {
				return ""
			}
		}
		return string(buf)
	case length <= 9:
		const alpha6 = "eilotrm.apdnsIc ufkMShjTRxgC4013bDNvwyUL2O856P-V%7+FKEWB9ZHYGQJ#zQX_&!?"
		buf := make([]byte, length)
		for i := 0; i < length; i++ {
			idx := int((payload >> (uint(i) * 6)) & 0x3f)
			if idx >= len(alpha6) {
				return ""
			}
			buf[i] = alpha6[idx]
		}
		return string(buf)
	default:
		const alpha5 = "eilotrm.apdnsIc ufkMShjTRxgC4013"
		buf := make([]byte, length)
		for i := 0; i < length; i++ {
			idx := int((payload >> (uint(i) * 5)) & 0x1f)
			if idx >= len(alpha5) {
				return ""
			}
			buf[i] = alpha5[idx]
		}
		return string(buf)
	}
}

func looksLikeRole(s string) bool {
	if len(s) < 4 {
		return false
	}
	if s[0] != 'A' || s[1] != 'X' {
		return false
	}
	for i := 2; i < len(s); i++ {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
			return false
		}
	}
	return true
}

// FindByLabel returns elements whose Label contains substr (case-sensitive).
func (t *Tree) FindByLabel(substr string) []*Element {
	t.mu.RLock()
	defer t.mu.RUnlock()
	var out []*Element
	for _, e := range t.elements {
		if e.Label != "" && strings.Contains(e.Label, substr) {
			out = append(out, e)
		}
	}
	return out
}

// FindByRole returns elements with exact role.
func (t *Tree) FindByRole(role string) []*Element {
	t.mu.RLock()
	defer t.mu.RUnlock()
	var out []*Element
	for _, e := range t.elements {
		if e.Role == role {
			out = append(out, e)
		}
	}
	return out
}

type flatRow struct {
	role, label string
	self        uint64
}

// FlatList renders one line per element with role + label, sorted by role.
func FlatList(t *Tree) string {
	t.mu.RLock()
	defer t.mu.RUnlock()
	var rows []flatRow
	for _, e := range t.elements {
		if e.Role == "" && e.Label == "" {
			continue
		}
		rows = append(rows, flatRow{e.Role, e.Label, e.Self})
	}
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0 && (rows[j-1].role > rows[j].role ||
			(rows[j-1].role == rows[j].role && rows[j-1].label > rows[j].label)); j-- {
			rows[j], rows[j-1] = rows[j-1], rows[j]
		}
	}
	var b strings.Builder
	for _, r := range rows {
		fmt.Fprintf(&b, "%-18s  %q  (0x%x)\n", nz(r.role, "?"), r.label, r.self)
	}
	return b.String()
}
