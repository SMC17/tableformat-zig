//! rbac: v0.0.7 port of P1066 (Apache Polaris four-tier RBAC).
//!
//! Polaris separates authorization into four tiers:
//!   Principal           (the human or service account)
//!   PrincipalRole       (group-like; principals are assigned to PR)
//!   CatalogRole         (catalog-scoped; PRs grant CRs)
//!   Grant               (privilege x securable; CRs hold grants)
//!
//! A principal's effective privileges are the union of grants held
//! by any catalog role reachable through any principal role they
//! belong to. This module ports that lattice as a graph with
//! transitive resolution.
//!
//! Composition with shipped tableformat-zig:
//!   * Securable is currently a fixed enum (catalog, table, view,
//!     namespace). It composes with manifest_entry.ManifestEntry.file
//!     when a caller wants per-file grants; that mapping lives at
//!     the caller boundary so the RBAC primitive stays decoupled
//!     from manifest representation.
//!   * schema_evolution.addColumn becomes guard-able by checking
//!     hasPrivilege(principal, .alter, .table) before applying.
//!
//! Scope of this revision:
//!   PrincipalId, PrincipalRoleId, CatalogRoleId types.
//!   Privilege enum (read, write, alter, drop, manage_grants).
//!   Securable enum (catalog, namespace, table, view).
//!   Grant record bundles a (CatalogRoleId, Privilege, Securable).
//!   Rbac store holds the four tiers as adjacency maps.
//!   assignPrincipalToRole / grantPrincipalRole / addGrant for writes.
//!   hasPrivilege walks the lattice and returns true on any path.
//!
//! Out of scope: securable hierarchies (namespace > table), grant
//! inheritance, OAuth token flow, audit log.

const std = @import("std");

pub const PrincipalId = u64;
pub const PrincipalRoleId = u64;
pub const CatalogRoleId = u64;

pub const Privilege = enum(u8) {
    read = 0,
    write = 1,
    alter = 2,
    drop = 3,
    manage_grants = 4,
};

pub const Securable = enum(u8) {
    catalog = 0,
    namespace = 1,
    table = 2,
    view = 3,
};

pub const Grant = struct {
    privilege: Privilege,
    securable: Securable,
};

pub const Error = error{ OutOfMemory };

const IdSet = std.AutoHashMap(u64, void);
const GrantSet = std.AutoHashMap(u64, void);

inline fn grantKey(g: Grant) u64 {
    return (@as(u64, @intFromEnum(g.privilege)) << 8) | @as(u64, @intFromEnum(g.securable));
}

pub const Rbac = struct {
    allocator: std.mem.Allocator,
    /// PrincipalId -> set of PrincipalRoleId.
    principal_to_roles: std.AutoHashMap(PrincipalId, IdSet),
    /// PrincipalRoleId -> set of CatalogRoleId.
    principal_role_to_catalog_roles: std.AutoHashMap(PrincipalRoleId, IdSet),
    /// CatalogRoleId -> set of grantKey(Grant).
    catalog_role_to_grants: std.AutoHashMap(CatalogRoleId, GrantSet),

    pub fn init(allocator: std.mem.Allocator) Rbac {
        return .{
            .allocator = allocator,
            .principal_to_roles = std.AutoHashMap(PrincipalId, IdSet).init(allocator),
            .principal_role_to_catalog_roles = std.AutoHashMap(PrincipalRoleId, IdSet).init(allocator),
            .catalog_role_to_grants = std.AutoHashMap(CatalogRoleId, GrantSet).init(allocator),
        };
    }

    pub fn deinit(self: *Rbac) void {
        var it_p = self.principal_to_roles.valueIterator();
        while (it_p.next()) |v| v.deinit();
        self.principal_to_roles.deinit();
        var it_r = self.principal_role_to_catalog_roles.valueIterator();
        while (it_r.next()) |v| v.deinit();
        self.principal_role_to_catalog_roles.deinit();
        var it_c = self.catalog_role_to_grants.valueIterator();
        while (it_c.next()) |v| v.deinit();
        self.catalog_role_to_grants.deinit();
    }

    /// Assign a principal to a principal role. Idempotent.
    pub fn assignPrincipalToRole(
        self: *Rbac,
        principal: PrincipalId,
        role: PrincipalRoleId,
    ) Error!void {
        const gop = self.principal_to_roles.getOrPut(principal) catch return Error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = IdSet.init(self.allocator);
        gop.value_ptr.put(role, {}) catch return Error.OutOfMemory;
    }

    /// Grant a principal role membership in a catalog role. Idempotent.
    pub fn grantPrincipalRole(
        self: *Rbac,
        principal_role: PrincipalRoleId,
        catalog_role: CatalogRoleId,
    ) Error!void {
        const gop = self.principal_role_to_catalog_roles.getOrPut(principal_role) catch return Error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = IdSet.init(self.allocator);
        gop.value_ptr.put(catalog_role, {}) catch return Error.OutOfMemory;
    }

    /// Add a grant to a catalog role. Idempotent in (privilege,
    /// securable) space.
    pub fn addGrant(
        self: *Rbac,
        catalog_role: CatalogRoleId,
        grant: Grant,
    ) Error!void {
        const gop = self.catalog_role_to_grants.getOrPut(catalog_role) catch return Error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = GrantSet.init(self.allocator);
        gop.value_ptr.put(grantKey(grant), {}) catch return Error.OutOfMemory;
    }

    /// Returns true iff some path principal -> PR -> CR -> Grant
    /// matches (privilege, securable). No path returns false; this
    /// includes the case of an unknown principal.
    pub fn hasPrivilege(
        self: *const Rbac,
        principal: PrincipalId,
        privilege: Privilege,
        securable: Securable,
    ) bool {
        const want = grantKey(.{ .privilege = privilege, .securable = securable });
        const prs = self.principal_to_roles.getPtr(principal) orelse return false;
        var it_pr = prs.keyIterator();
        while (it_pr.next()) |pr| {
            const crs = self.principal_role_to_catalog_roles.getPtr(pr.*) orelse continue;
            var it_cr = crs.keyIterator();
            while (it_cr.next()) |cr| {
                const grants = self.catalog_role_to_grants.getPtr(cr.*) orelse continue;
                if (grants.contains(want)) return true;
            }
        }
        return false;
    }

    pub fn principalRoleCount(self: *const Rbac, principal: PrincipalId) usize {
        const prs = self.principal_to_roles.getPtr(principal) orelse return 0;
        return prs.count();
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "unknown principal has no privilege" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try testing.expect(!rbac.hasPrivilege(1, .read, .table));
}

test "single chain grants privilege" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.grantPrincipalRole(10, 100);
    try rbac.addGrant(100, .{ .privilege = .read, .securable = .table });
    try testing.expect(rbac.hasPrivilege(1, .read, .table));
}

test "chain stops if any link missing" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    // No grantPrincipalRole link.
    try rbac.addGrant(100, .{ .privilege = .read, .securable = .table });
    try testing.expect(!rbac.hasPrivilege(1, .read, .table));
}

test "privilege match is exact on (privilege, securable)" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.grantPrincipalRole(10, 100);
    try rbac.addGrant(100, .{ .privilege = .read, .securable = .table });
    try testing.expect(rbac.hasPrivilege(1, .read, .table));
    try testing.expect(!rbac.hasPrivilege(1, .write, .table));
    try testing.expect(!rbac.hasPrivilege(1, .read, .view));
}

test "principal with two PRs walks both paths" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.assignPrincipalToRole(1, 11);
    try rbac.grantPrincipalRole(10, 100);
    try rbac.grantPrincipalRole(11, 101);
    try rbac.addGrant(101, .{ .privilege = .alter, .securable = .table });
    try testing.expect(rbac.hasPrivilege(1, .alter, .table));
}

test "PR shared by two CRs unions grants" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.grantPrincipalRole(10, 100);
    try rbac.grantPrincipalRole(10, 101);
    try rbac.addGrant(100, .{ .privilege = .read, .securable = .table });
    try rbac.addGrant(101, .{ .privilege = .write, .securable = .table });
    try testing.expect(rbac.hasPrivilege(1, .read, .table));
    try testing.expect(rbac.hasPrivilege(1, .write, .table));
}

test "assignPrincipalToRole is idempotent" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.assignPrincipalToRole(1, 10);
    try testing.expectEqual(@as(usize, 1), rbac.principalRoleCount(1));
}

test "addGrant is idempotent in (privilege, securable)" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.grantPrincipalRole(10, 100);
    try rbac.addGrant(100, .{ .privilege = .read, .securable = .table });
    try rbac.addGrant(100, .{ .privilege = .read, .securable = .table });
    try testing.expect(rbac.hasPrivilege(1, .read, .table));
}

test "two principals have independent reachability" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.grantPrincipalRole(10, 100);
    try rbac.addGrant(100, .{ .privilege = .read, .securable = .table });
    try testing.expect(rbac.hasPrivilege(1, .read, .table));
    try testing.expect(!rbac.hasPrivilege(2, .read, .table));
}

test "manage_grants is just another privilege key" {
    var rbac: Rbac = .init(testing.allocator);
    defer rbac.deinit();
    try rbac.assignPrincipalToRole(1, 10);
    try rbac.grantPrincipalRole(10, 100);
    try rbac.addGrant(100, .{ .privilege = .manage_grants, .securable = .catalog });
    try testing.expect(rbac.hasPrivilege(1, .manage_grants, .catalog));
    try testing.expect(!rbac.hasPrivilege(1, .manage_grants, .table));
}
