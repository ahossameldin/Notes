# EF Core Performance & DbContext Behavior (Cheat Sheet)

This document summarizes how **Entity Framework Core** works internally and the key optimizations you should keep in mind for high-concurrency backend systems.

---

# 1. DbContext Lifetime (VERY IMPORTANT)

In ASP.NET Core, `DbContext` is registered as **Scoped**:

```csharp
builder.Services.AddDbContext<AppDbContext>();
```

### Meaning:

* 1 DbContext per HTTP request
* Not shared across threads
* Automatically disposed at end of request

### Example:

```
Request A → DbContext A
Request B → DbContext B
```

### Key idea:

DbContext = **Unit of Work per request**

---

# 2. Change Tracking (Default Behavior)

EF Core tracks entities returned from queries:

```csharp
var users = await context.Users.ToListAsync();
```

Now each `User` is tracked:

* original values stored
* changes detected automatically
* SaveChanges generates UPDATEs

---

# 3. AsNoTracking (READ OPTIMIZATION)

Use this for read-only queries:

```csharp
var users = await context.Users
    .AsNoTracking()
    .ToListAsync();
```

### What it does:

* disables ChangeTracker
* avoids memory overhead
* faster query execution

### When to use:

* APIs returning data
* reports
* read-only endpoints

### When NOT to use:

* updates
* business logic modifications

---

# 4. DbContext Pooling (High Performance)

Instead of creating/discarding contexts:

```csharp
builder.Services.AddDbContextPool<AppDbContext>();
```

### Benefits:

* reuses DbContext instances
* reduces GC pressure
* faster under high load

### Tradeoff:

* must avoid leaking state between requests (EF resets internally, but you must still be careful)

---

# 5. Compiled Queries (Hot Path Optimization)

For frequently executed queries:

```csharp
private static readonly Func<AppDbContext, int, Task<User?>> GetUserById =
    EF.CompileAsyncQuery((AppDbContext ctx, int id) =>
        ctx.Users
            .AsNoTracking()
            .FirstOrDefault(u => u.Id == id));
```

Usage:

```csharp
var user = await GetUserById(context, 1);
```

### Benefits:

* avoids expression tree compilation each time
* faster execution for hot queries

---

# 6. Tracking vs No-Tracking Decision Rule

| Scenario        | Use                  |
| --------------- | -------------------- |
| Read-only API   | AsNoTracking         |
| Update workflow | Tracking (default)   |
| Mixed logic     | Selective projection |

---

# 7. Projection Optimization (VERY IMPORTANT)

Instead of loading full entities:

```csharp
var users = await context.Users
    .Select(u => new UserDto
    {
        Id = u.Id,
        Name = u.Name
    })
    .ToListAsync();
```

### Why:

* reduces memory usage
* reduces SQL payload
* avoids unnecessary tracking

---

# 8. Avoid N+1 Queries

Bad:

```csharp
foreach (var user in users)
{
    var role = await context.Roles.FindAsync(user.RoleId);
}
```

Good:

```csharp
var users = await context.Users
    .Include(u => u.Role)
    .ToListAsync();
```

---

# 9. ChangeTracker Overhead

EF Core stores:

* Original values
* Current values
* Entity states
* Navigation graph

### Disable tracking when not needed:

```csharp
context.ChangeTracker.QueryTrackingBehavior = QueryTrackingBehavior.NoTracking;
```

---

# 10. Concurrency Awareness

EF Core does NOT prevent race conditions automatically.

Use concurrency tokens:

```csharp
[Timestamp]
public byte[] RowVersion { get; set; }
```

Prevents silent overwrites.

---

# 11. Real-World Scaling Model

For high traffic systems:

* DbContext instances = concurrent requests
* NOT number of users
* lifetime = milliseconds

Example:

```
10k users ≠ 10k DbContexts
10k concurrent requests ≈ 10k DbContexts
```

---

# Summary Mental Model

Think of EF Core like this:

> DbContext = short-lived workspace
> ChangeTracker = in-memory diff engine
> Database = source of truth

Optimize by:

* reducing tracking
* reducing data load
* reusing compiled logic
* avoiding unnecessary entity materialization
