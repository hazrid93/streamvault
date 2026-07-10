import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = fs
  .readFileSync(new URL("../../app/javascript/controllers/stream_filter_controller.js", import.meta.url), "utf8")
  .replace(/^import .*$/m, "class Controller {}")
  .replace("export default class", "globalThis.StreamFilterController = class")

const context = vm.createContext({ console })
vm.runInContext(source, context)
const StreamFilterController = context.StreamFilterController

function row({ title, rd = false, seeders = "", quality = "1080p", size = 0 }) {
  return {
    title,
    dataset: { rdPlus: rd.toString(), seeders: seeders.toString(), quality, size: size.toString() }
  }
}

test("default ordering groups RD rows first and sorts each group by seeders", () => {
  const controller = new StreamFilterController()
  const rows = [
    row({ title: "non-RD unknown", quality: "4K" }),
    row({ title: "RD low", rd: true, seeders: 2 }),
    row({ title: "non-RD high", seeders: 90 }),
    row({ title: "RD unknown", rd: true, quality: "4K" }),
    row({ title: "RD high", rd: true, seeders: 30 }),
    row({ title: "non-RD low", seeders: 4 })
  ]
  rows.forEach((item, index) => { item.dataset.originalIndex = index })
  controller.sortMode = "seeders"

  rows.sort((a, b) => controller.compareRows(a, b))

  assert.deepEqual(rows.map((item) => item.title), [
    "RD high",
    "RD low",
    "RD unknown",
    "non-RD high",
    "non-RD low",
    "non-RD unknown"
  ])
})

test("RD grouping remains in force for optional quality and size sorts", () => {
  const controller = new StreamFilterController()
  const rd = row({ title: "RD", rd: true, quality: "720p", size: 1 })
  const nonRd = row({ title: "non-RD", quality: "4K", size: 100 })

  controller.sortMode = "quality"
  assert.ok(controller.compareRows(rd, nonRd) < 0)

  controller.sortMode = "size"
  assert.ok(controller.compareRows(rd, nonRd) < 0)
})

test("known zero seeders sorts ahead of an unavailable count", () => {
  const controller = new StreamFilterController()
  controller.sortMode = "seeders"
  const zero = row({ title: "zero", seeders: 0 })
  const unknown = row({ title: "unknown" })

  assert.ok(controller.compareRows(zero, unknown) < 0)
})
