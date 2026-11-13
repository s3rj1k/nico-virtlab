# Line based edits of the TOML site config embedded in nico-core.yaml.
load("@ytt:assert", "assert")

def _is_key(l, key):
  return l.startswith(key + " =") or l.startswith(key + "=")
end

def quoted(xs):
  return ", ".join(['"' + x + '"' for x in xs])
end

# Replace the value of a root key, failing if the key is gone upstream.
def set_key(s, key, value):
  out = []
  hits = 0
  for l in s.split("\n"):
    if _is_key(l, key):
      out.append(key + " = " + value)
      hits += 1
    else:
      out.append(l)
    end
  end
  if hits != 1:
    assert.fail("site config key " + key + " found " + str(hits) + " times")
  end
  return "\n".join(out)
end

# Add lines right after the line of a root key.
def insert_after(s, key, lines):
  out = []
  for l in s.split("\n"):
    out.append(l)
    if _is_key(l, key):
      out.extend(lines)
    end
  end
  return "\n".join(out)
end

# Value of a root key holding a string list.
def get_list(s, key):
  for l in s.split("\n"):
    if _is_key(l, key):
      body = l[l.index("[") + 1:l.index("]")]
      return [x.strip().strip('"') for x in body.split(",") if x.strip()]
    end
  end
  assert.fail("site config key " + key + " not found")
end

# Lines for one [networks.<name>] table.
def network(name, type, prefix, gateway, mtu, reserve_first, vpc_name=""):
  lines = [
    "",
    "[networks." + name + "]",
    'type = "' + type + '"',
    'prefix = "' + prefix + '"',
    'gateway = "' + gateway + '"',
    "mtu = " + str(mtu),
    "reserve_first = " + str(reserve_first),
  ]
  if vpc_name:
    lines.append('vpc_name = "' + vpc_name + '"')
  end
  return lines
end

# Append tables at the end, TOML does not care where a table starts.
def append(s, lines):
  return s.rstrip("\n") + "\n" + "\n".join(lines) + "\n"
end
