```rust
alloc::vec::Vec
```

```rust
pub fn with_capacity(capacity: usize) -> Self
```

---

Constructs a new, empty `Vec<T>` with at least the specified capacity.

The vector will be able to hold at least `capacity` elements without
reallocating. See [`Vec::reserve`] for details.

# Panics

Panics if the new capacity exceeds `isize::MAX` _bytes_.

# Examples

```rust
let mut vec = Vec::with_capacity(10);
assert_eq!(vec.len(), 0);
```

[`Vec::reserve`]: https://doc.rust-lang.org/stable/alloc/vec/struct.Vec.html#method.reserve
