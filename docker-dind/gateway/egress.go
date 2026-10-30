package main

import (
	"cmp"
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"
	"slices"
)

// ipRange is an inclusive IPv4 range.
type ipRange struct{ lo, hi uint32 }

func (r ipRange) String() string {
	lo, hi := u32ToAddr(r.lo), u32ToAddr(r.hi)
	if r.lo == r.hi {
		return lo.String()
	}
	return lo.String() + "-" + hi.String()
}

func u32ToAddr(v uint32) netip.Addr {
	var a [4]byte
	binary.BigEndian.PutUint32(a[:], v)
	return netip.AddrFrom4(a)
}

func prefixRange(p netip.Prefix) ipRange {
	lo := binary.BigEndian.Uint32(p.Masked().Addr().AsSlice())
	return ipRange{lo, lo | (uint32(1)<<(32-p.Bits()) - 1)}
}

// parseRanges reads IPv4 CIDRs or single addresses.
func parseRanges(items []string) ([]ipRange, error) {
	var out []ipRange
	for _, s := range items {
		if p, err := netip.ParsePrefix(s); err == nil {
			if !p.Addr().Is4() {
				return nil, fmt.Errorf("%s: only IPv4 is supported (Windows NAT networks are IPv4 only)", s)
			}
			out = append(out, prefixRange(p))
			continue
		}
		a, err := netip.ParseAddr(s)
		if err != nil || !a.Is4() {
			return nil, fmt.Errorf("%q is not an IPv4 address or CIDR", s)
		}
		v := binary.BigEndian.Uint32(a.AsSlice())
		out = append(out, ipRange{v, v})
	}
	return out, nil
}

// normalize sorts and merges overlapping or adjacent ranges.
func normalize(rs []ipRange) []ipRange {
	rs = slices.Clone(rs)
	slices.SortFunc(rs, func(a, b ipRange) int { return cmp.Compare(a.lo, b.lo) })
	var out []ipRange
	for _, r := range rs {
		if n := len(out); n > 0 && (r.lo <= out[n-1].hi || out[n-1].hi != ^uint32(0) && r.lo == out[n-1].hi+1) {
			out[n-1].hi = max(out[n-1].hi, r.hi)
			continue
		}
		out = append(out, r)
	}
	return out
}

// subtract removes the allow ranges from the block ranges.
func subtract(block, allow []ipRange) []ipRange {
	block, allow = normalize(block), normalize(allow)
	var out []ipRange
	for _, b := range block {
		cur := []ipRange{b}
		for _, a := range allow {
			var next []ipRange
			for _, c := range cur {
				if a.hi < c.lo || a.lo > c.hi {
					next = append(next, c)
					continue
				}
				if a.lo > c.lo {
					next = append(next, ipRange{c.lo, a.lo - 1})
				}
				if a.hi < c.hi {
					next = append(next, ipRange{a.hi + 1, c.hi})
				}
			}
			cur = next
		}
		out = append(out, cur...)
	}
	return out
}

// egressBlockRanges is what build containers may not reach: the configured block list, the
// tenant pool (other tenants) and the node's own addresses, minus the allow list and the DNS
// servers handed to containers.
func egressBlockRanges(cfg *Config, hostAddrs []netip.Addr) ([]string, error) {
	block, err := parseRanges(append(slices.Clone(cfg.Network.Egress.Block), cfg.Network.Pool))
	if err != nil {
		return nil, fmt.Errorf("network.egress.block: %w", err)
	}
	for _, a := range hostAddrs {
		if a.Is4() && !a.IsLoopback() {
			v := binary.BigEndian.Uint32(a.AsSlice())
			block = append(block, ipRange{v, v})
		}
	}
	allow, err := parseRanges(append(slices.Clone(cfg.Network.Egress.Allow), cfg.Network.DNS...))
	if err != nil {
		return nil, fmt.Errorf("network.egress.allow: %w", err)
	}
	var out []string
	for _, r := range subtract(block, allow) {
		out = append(out, r.String())
	}
	return out, nil
}

func hostAddresses() ([]netip.Addr, error) {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil, err
	}
	var out []netip.Addr
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok {
			if ip, ok := netip.AddrFromSlice(n.IP); ok {
				out = append(out, ip.Unmap())
			}
		}
	}
	return out, nil
}
