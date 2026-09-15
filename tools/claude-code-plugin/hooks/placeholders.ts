import { DIACRITICS, PLACEHOLDER } from './diacritics.ts'

/** Largest grid the placeholder diacritic table can address, per side. */
export const MAX_GRID = DIACRITICS.length

/** The 24-bit foreground that names image `id` in a placeholder cell. */
export const fgHex = (id: number): string => `#${(id & 0xffffff).toString(16).padStart(6, '0')}`

/** One grid row: every cell carries its row and column diacritic. */
export function rowText(row: number, cols: number): string {
  const r = DIACRITICS[row] ?? ''
  let out = ''
  for (let c = 0; c < cols; c++) out += PLACEHOLDER + r + (DIACRITICS[c] ?? '')
  return out
}

export type Grid = { cols: number; rows: number }
export type SourcePx = { w: number; h: number } | null

/**
 * The largest grid inside `maxCols` x `maxRows` that keeps the source's pixel
 * aspect, given a terminal cell `cellAspect` = width / height (about 0.5).
 * Without a source size, the whole box.
 */
export function fitGrid(source: SourcePx, maxCols: number, maxRows: number, cellAspect = 0.5): Grid {
  const capCols = Math.max(1, Math.min(MAX_GRID, Math.floor(maxCols)))
  const capRows = Math.max(1, Math.min(MAX_GRID, Math.floor(maxRows)))
  if (!source || source.w <= 0 || source.h <= 0) return { cols: capCols, rows: capRows }
  const aspect = source.w / source.h
  let rows = capRows
  let cols = Math.round((rows * aspect) / cellAspect)
  if (cols > capCols) {
    cols = capCols
    rows = Math.round((cols * cellAspect) / aspect)
  }
  return { cols: Math.max(1, cols), rows: Math.max(1, rows) }
}
