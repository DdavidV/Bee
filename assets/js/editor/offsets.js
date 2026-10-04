// The server counts text positions in UTF-8 bytes (Elixir binaries),
// CodeMirror in UTF-16 code units. These convert between the two for a
// document string, in one pass over it.

const utf8Length = (text, i) => {
  const c = text.charCodeAt(i)
  if (c < 0x80) return [1, 1]
  if (c < 0x800) return [2, 1]
  // A surrogate pair is one code point: 4 bytes, 2 code units.
  if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) return [4, 2]
  return [3, 1]
}

// UTF-16 offsets -> Map(offset -> UTF-8 byte offset)
export const toBytes = (text, offsets) => {
  const wanted = [...new Set(offsets)].sort((a, b) => a - b)
  const result = new Map()
  let i = 0, bytes = 0, k = 0
  while (k < wanted.length) {
    if (i >= wanted[k] || i >= text.length) {
      result.set(wanted[k], bytes)
      k++
      continue
    }
    const [b, units] = utf8Length(text, i)
    bytes += b
    i += units
  }
  return result
}

// UTF-8 byte offsets -> Map(bytes -> UTF-16 offset); offsets that aren't on
// a character boundary, or past the end, are missing from the map.
export const fromBytes = (text, byteOffsets) => {
  const wanted = [...new Set(byteOffsets)].sort((a, b) => a - b)
  const result = new Map()
  let i = 0, bytes = 0, k = 0
  while (k < wanted.length) {
    if (bytes === wanted[k]) {
      result.set(wanted[k], i)
      k++
    } else if (bytes > wanted[k] || i >= text.length) {
      k++
    } else {
      const [b, units] = utf8Length(text, i)
      bytes += b
      i += units
    }
  }
  return result
}
