package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"sync"
)

// subnetStore hands each tenant a subnet of the pool and remembers it in a JSON file, so
// allocations survive restarts and never move between tenants.
type subnetStore struct {
	path string
	pool netip.Prefix
	bits int

	mu       sync.Mutex
	assigned map[string]string // tenant ID -> subnet
}

func openSubnetStore(path, pool string, bits int) (*subnetStore, error) {
	p, err := netip.ParsePrefix(pool)
	if err != nil {
		return nil, err
	}
	s := &subnetStore{path: path, pool: p, bits: bits, assigned: map[string]string{}}
	b, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(b, &s.assigned); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}
	return s, nil
}

// allocate returns the tenant's subnet, assigning the first free one if it has none or if its
// current one is in skip (known not to work).
func (s *subnetStore) allocate(id string, skip map[string]bool) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cur, ok := s.assigned[id]; ok && !skip[cur] && s.inPool(cur) {
		return cur, nil
	}
	used := make(map[string]bool, len(s.assigned))
	for tid, sn := range s.assigned {
		if tid != id {
			used[sn] = true
		}
	}
	base := binary.BigEndian.Uint32(s.pool.Addr().AsSlice())
	step := uint32(1) << (32 - s.bits)
	count := uint64(1) << (s.bits - s.pool.Bits())
	for i := uint64(0); i < count; i++ {
		var a [4]byte
		binary.BigEndian.PutUint32(a[:], base+uint32(i)*step)
		sn := netip.PrefixFrom(netip.AddrFrom4(a), s.bits).String()
		if used[sn] || skip[sn] {
			continue
		}
		s.assigned[id] = sn
		return sn, s.save()
	}
	return "", fmt.Errorf("network pool %s has no free /%d subnet left", s.pool, s.bits)
}

func (s *subnetStore) inPool(sn string) bool {
	p, err := netip.ParsePrefix(sn)
	return err == nil && p.Bits() == s.bits && s.pool.Contains(p.Addr())
}

func (s *subnetStore) save() error {
	b, err := json.MarshalIndent(s.assigned, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
