/**
 * DSH Computer Use — a Qoder-style desktop controller.
 *
 * The model gets window-scoped tools over a long-lived PowerShell helper:
 * UI Automation for element trees and element actions, SendInput for keyboard
 * and pointer input, and PrintWindow captures that survive occlusion. Every
 * pointer coordinate is bound to a screenshot id, so a stale observation cannot
 * silently aim at the wrong pixel.
 */
import { spawn } from 'node:child_process'
import { mkdir, readFile, stat } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import readline from 'node:readline'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const HELPER_SCRIPT = path.join(HERE, 'cua.ps1')
const SKILL_FILE = path.join(HERE, 'skills', 'computer-use', 'SKILL.md')
const SCREENSHOT_DIR = path.join(os.tmpdir(), 'dsh-computer-use')

const DEFAULT_TIMEOUT_MS = 45_000
const SKILL_NAME = 'computer-use'

/** Tools and the skill registry the feature needs. */
export const inject = ['tools', 'skills']

function powershellExe() {
  const root = process.env.SystemRoot || process.env.windir || 'C:\\Windows'
  return path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
}

/** One long-lived helper process with serialized request/response over NDJSON. */
class HelperClient {
  constructor() {
    this.child = undefined
    this.pending = new Map()
    this.sequence = 0
    this.queue = Promise.resolve()
    this.closing = false
  }

  async ensure() {
    if (this.child !== undefined && this.child.exitCode === null) return
    await mkdir(SCREENSHOT_DIR, { recursive: true })
    const child = spawn(
      powershellExe(),
      ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', HELPER_SCRIPT, '-ScreenshotDir', SCREENSHOT_DIR],
      { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] },
    )
    this.child = child
    child.stderr.on('data', () => {})
    const lines = readline.createInterface({ input: child.stdout })
    lines.on('line', (line) => {
      let message
      try {
        message = JSON.parse(line)
      } catch {
        return
      }
      const settle = this.pending.get(message.id)
      if (settle === undefined) return
      this.pending.delete(message.id)
      settle(message)
    })
    child.on('exit', () => {
      for (const settle of this.pending.values()) settle({ ok: false, error: 'computer-use helper exited' })
      this.pending.clear()
      if (this.child === child) this.child = undefined
    })
  }

  /** Run one helper method; calls are serialized because the protocol is. */
  call(method, params, { signal, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
    const run = () => this.runNow(method, params, signal, timeoutMs)
    const next = this.queue.then(run, run)
    this.queue = next.then(
      () => undefined,
      () => undefined,
    )
    return next
  }

  async runNow(method, params, signal, timeoutMs) {
    await this.ensure()
    const child = this.child
    if (child === undefined) throw new Error('computer-use helper is unavailable')
    if (signal?.aborted) throw new Error('cancelled')

    const id = ++this.sequence
    const response = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`computer-use helper timed out after ${timeoutMs}ms (${method})`))
      }, timeoutMs)
      const onAbort = () => {
        clearTimeout(timer)
        this.pending.delete(id)
        reject(new Error('cancelled'))
      }
      signal?.addEventListener('abort', onAbort, { once: true })
      this.pending.set(id, (message) => {
        clearTimeout(timer)
        signal?.removeEventListener('abort', onAbort)
        resolve(message)
      })
      child.stdin.write(JSON.stringify({ id, method, params }) + '\n')
    })

    if (response.ok !== true) throw new Error(response.error ?? `computer-use helper failed: ${method}`)
    return response.result
  }

  async dispose() {
    this.closing = true
    const child = this.child
    this.child = undefined
    if (child === undefined) return
    try {
      child.stdin.write(JSON.stringify({ id: 0, method: 'close', params: {} }) + '\n')
    } catch {
      /* already gone */
    }
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, 1500)
      child.on('exit', () => {
        clearTimeout(timer)
        resolve()
      })
      try {
        child.kill()
      } catch {
        clearTimeout(timer)
        resolve()
      }
    })
  }
}

/** Whether the exact routed model declares image input. */
async function canViewImages(ctx, exec) {
  try {
    const routed = exec.agent?.session?.requestHeader?.()?.config
    const provider = routed?.provider ?? exec.agent?.options?.provider
    const model = routed?.model ?? exec.agent?.options?.model
    const llm = ctx.get('llm')
    if (provider === undefined || model === undefined || llm === undefined) return false
    const info = await llm.resolveModelInfo(provider, model, exec.signal)
    return Array.isArray(info?.inputModalities) && info.inputModalities.includes('image')
  } catch {
    return false
  }
}

/** Drop null/undefined members so the tool value stays lossless JSON with declared types. */
function clean(value) {
  if (Array.isArray(value)) return value.map(clean)
  if (value !== null && typeof value === 'object') {
    const out = {}
    for (const [key, entry] of Object.entries(value)) {
      if (entry === null || entry === undefined) continue
      out[key] = clean(entry)
    }
    return out
  }
  return value
}

function lossless(value) {
  return clean(JSON.parse(JSON.stringify(value)))
}

function textOnly(value) {
  return [{ type: 'text', text: JSON.stringify(value, null, 2) }]
}

function windowLine(window) {
  if (window === undefined || window === null) return 'window: (unknown)'
  const parts = [`window_id=${window.id}`, `title="${window.title ?? ''}"`]
  if (typeof window.app === 'string' && window.app.length > 0) parts.push(`app="${path.basename(window.app)}"`)
  if (window.bounds !== undefined && window.bounds !== null) {
    parts.push(`bounds=${window.bounds.width}x${window.bounds.height}@${window.bounds.x},${window.bounds.y}`)
  }
  return parts.join(' ')
}

function stateEnvelope(value) {
  const lines = []
  lines.push('<window>' + windowLine(value.window) + '</window>')
  const shot = value.screenshot
  if (shot !== undefined) {
    lines.push(
      `<screenshot id="${shot.id}" width="${shot.width}" height="${shot.height}" origin="${shot.originX},${shot.originY}">` +
        'pass this id with x/y coordinates in its pixel space' +
        '</screenshot>',
    )
  }
  const accessibility = value.accessibility ?? {}
  if (accessibility.focused_element) lines.push('<focused>' + accessibility.focused_element + '</focused>')
  if (accessibility.selected_text) lines.push('<selected_text>' + accessibility.selected_text.slice(0, 400) + '</selected_text>')
  if (accessibility.document_text) lines.push('<document_text>' + accessibility.document_text.slice(0, 6000) + '</document_text>')
  if (accessibility.tree) lines.push('<accessibility_tree>\n' + accessibility.tree + '\n</accessibility_tree>')
  return lines.join('\n')
}

function renderState(_args, value) {
  const content = [{ type: 'text', text: stateEnvelope(value) }]
  if (value.image !== undefined) {
    content.push({ type: 'image', attachment: { ...value.image } })
  }
  return content
}

const STATE_SCHEMA = {
  type: 'object',
  additionalProperties: true,
  properties: {
    window: {
      type: 'object',
      additionalProperties: true,
      properties: {
        id: { type: 'number' },
        title: { type: 'string' },
        app: { type: 'string' },
        className: { type: 'string' },
      },
    },
    screenshot: {
      type: 'object',
      additionalProperties: true,
      properties: {
        id: { type: 'string' },
        path: { type: 'string' },
        width: { type: 'number' },
        height: { type: 'number' },
        originX: { type: 'number' },
        originY: { type: 'number' },
      },
    },
    accessibility: {
      type: 'object',
      additionalProperties: true,
      properties: {
        tree: { type: 'string' },
        document_text: { type: 'string' },
        focused_element: { type: 'string' },
        selected_text: { type: 'string' },
      },
    },
    image: {
      type: 'object',
      additionalProperties: true,
      properties: {
        attachmentId: { type: 'string' },
        mediaType: { type: 'string' },
        bytes: { type: 'number' },
        width: { type: 'number' },
        height: { type: 'number' },
        name: { type: 'string' },
      },
    },
  },
}

const WINDOW_ID = { type: 'integer', description: '目标窗口 id（来自 computer_list_windows / computer_list_apps）。' }
const SCREENSHOT_ID = { type: 'string', description: 'computer_get_window_state 返回的截图 id；坐标动作必须带上它，防止用过期的像素坐标。' }

/**
 * Register the computer-use tools and its model-facing skill.
 * @param ctx - owning plugin context.
 * @param config - optional `timeoutMs` override per helper call.
 */
export function apply(ctx, config) {
  if (process.platform !== 'win32') return
  const settings = config !== null && typeof config === 'object' ? config : {}
  const timeoutMs = Number.isInteger(settings.timeoutMs) && settings.timeoutMs > 5000 ? settings.timeoutMs : DEFAULT_TIMEOUT_MS
  const client = new HelperClient()

  ctx.effect(() => () => client.dispose(), 'computer-use: helper lifecycle')

  const call = (method, params, exec, extra = {}) =>
    client.call(method, params, { signal: exec?.signal, timeoutMs: extra.timeoutMs ?? timeoutMs })

  function registerTool(definition) {
    return ctx.effect(() => ctx.tools.register(definition), `computer-use: ${definition.name}`)
  }

  registerTool({
    name: 'computer_list_windows',
    description:
      '列出当前可操作的可见窗口（id、标题、进程、窗口矩形）。控制桌面前先用它选目标窗口；窗口可能被遮挡，截图用 PrintWindow，不需要先切到前台。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: {
      schema: { type: 'object', additionalProperties: true, properties: { windows: { type: 'array', items: { type: 'object', additionalProperties: true } } } },
      render: (_args, value) => [
        {
          type: 'text',
          text: (value.windows ?? [])
            .map((w) => `- ${windowLine(w)}${w.className ? ` class="${w.className}"` : ''}`)
            .join('\n'),
        },
      ],
    },
    async execute(_args, exec) {
      const windows = await call('list_windows', {}, exec)
      return { windows: Array.isArray(windows) ? windows : [] }
    },
  })

  registerTool({
    name: 'computer_list_apps',
    description: '按应用分组列出当前有窗口的进程（app 是可执行文件路径，windows 是它的窗口）。目标应用没有窗口时用 computer_launch_app 启动。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: {
      schema: { type: 'object', additionalProperties: true, properties: { apps: { type: 'array', items: { type: 'object', additionalProperties: true } } } },
      render: (_args, value) =>
        [
          {
            type: 'text',
            text: (value.apps ?? [])
              .map((app) => `- ${app.id}\n  windows: ${(app.windows ?? []).map((w) => `${w.id} "${w.title}"`).join(' | ') || '(none)'}`)
              .join('\n'),
          },
        ],
    },
    async execute(_args, exec) {
      const apps = await call('list_apps', {}, exec)
      return { apps: Array.isArray(apps) ? apps : [] }
    },
  })

  registerTool({
    name: 'computer_get_window_state',
    description:
      '观察一个窗口：截图（默认开）和/或 UI Automation 元素树（include_text=true 时返回带编号的元素、document_text、focused_element）。元素编号只对本次观察有效；坐标必须使用本次返回的 screenshot id。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id'],
      properties: {
        window_id: WINDOW_ID,
        include_screenshot: { type: 'boolean', description: '是否截图，默认 true。' },
        include_text: { type: 'boolean', description: '是否返回无障碍元素树与文本，默认 false。' },
      },
    },
    output: { schema: STATE_SCHEMA, render: renderState },
    timeoutMs: 120_000,
    async execute(args, exec) {
      const state = await call(
        'get_window_state',
        {
          window_id: args.window_id,
          include_screenshot: args.include_screenshot ?? true,
          include_text: args.include_text ?? false,
        },
        exec,
        { timeoutMs: 60_000 },
      )
      const value = {
        window: state.window,
        accessibility: state.accessibility,
        screenshot: undefined,
        image: undefined,
      }
      const shot = Array.isArray(state.screenshots) ? state.screenshots[0] : undefined
      if (shot !== undefined) {
        value.screenshot = {
          id: shot.id,
          path: shot.path,
          width: shot.width,
          height: shot.height,
          originX: shot.originX,
          originY: shot.originY,
        }
        if (await canViewImages(ctx, exec)) {
          const attachments = ctx.get('attachments')
          if (attachments !== undefined) {
            try {
              const data = await readFile(shot.path)
              const ref = await attachments.saveImage({ data, mediaType: 'image/png', name: path.basename(shot.path) })
              value.image = {
                attachmentId: ref.attachmentId,
                mediaType: ref.mediaType,
                bytes: ref.bytes,
                width: ref.width,
                height: ref.height,
                name: ref.name ?? path.basename(shot.path),
              }
            } catch {
              /* the picture stays on disk; the text envelope still names it */
            }
          }
        }
      }
      return lossless(value)
    },
  })

  registerTool({
    name: 'computer_click',
    description:
      '点击一个窗口：优先用 element_index（来自最近一次 get_window_state 的元素树，走 UI Automation 的 Invoke/Toggle/Select/Expand，不移动真实鼠标），否则用 screenshot_id + x/y（截图像素坐标）。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id'],
      properties: {
        window_id: WINDOW_ID,
        element_index: { type: 'integer', description: '最近一次元素树里的元素编号。' },
        screenshot_id: SCREENSHOT_ID,
        x: { type: 'integer', description: '截图像素 x。' },
        y: { type: 'integer', description: '截图像素 y。' },
        click_count: { type: 'integer', description: '点击次数，默认 1。' },
        mouse_button: { type: 'string', enum: ['left', 'right', 'middle'], description: '默认 left。' },
      },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    async execute(args, exec) {
      const result = await call(
        'click',
        {
          window_id: args.window_id,
          element_index: args.element_index,
          screenshot_id: args.screenshot_id,
          x: args.x,
          y: args.y,
          click_count: args.click_count,
          mouse_button: args.mouse_button,
        },
        exec,
      )
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_type_text',
    description:
      '向窗口当前焦点逐字输入文本（SendInput Unicode）。Windows 要求目标窗口在前台：helper 会先激活它，激活失败会明确报错而不是把字打到别的窗口。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id', 'text'],
      properties: { window_id: WINDOW_ID, text: { type: 'string', description: '要输入的字面文本。' } },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    timeoutMs: 180_000,
    async execute(args, exec) {
      const result = await call('type_text', { window_id: args.window_id, text: args.text }, exec, { timeoutMs: 120_000 })
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_press_key',
    description:
      '发送一个按键或组合键（X keysym 风格，如 Return、Tab、Control_L+a、Control_L+Shift_L+period、KP_0）。同样要求目标窗口在前台。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id', 'key'],
      properties: { window_id: WINDOW_ID, key: { type: 'string', description: '按键或 + 连接的组合键。' } },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    async execute(args, exec) {
      const result = await call('press_key', { window_id: args.window_id, key: args.key }, exec)
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_scroll',
    description: '在截图像素坐标 (x, y) 处滚动窗口；scrollY 正数向下、负数向上，scrollX 正数向右。必须带 screenshot_id。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id', 'screenshot_id', 'x', 'y'],
      properties: {
        window_id: WINDOW_ID,
        screenshot_id: SCREENSHOT_ID,
        x: { type: 'integer' },
        y: { type: 'integer' },
        scrollX: { type: 'integer', description: '水平滚动量，默认 0。' },
        scrollY: { type: 'integer', description: '垂直滚动量，默认 0。' },
      },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    async execute(args, exec) {
      const result = await call(
        'scroll',
        {
          window_id: args.window_id,
          screenshot_id: args.screenshot_id,
          x: args.x,
          y: args.y,
          scrollX: args.scrollX ?? 0,
          scrollY: args.scrollY ?? 0,
        },
        exec,
      )
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_drag',
    description: '从截图坐标 (from_x, from_y) 拖到 (to_x, to_y)；用于画布、滑块、拖拽排序。必须带 screenshot_id。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id', 'screenshot_id', 'from_x', 'from_y', 'to_x', 'to_y'],
      properties: {
        window_id: WINDOW_ID,
        screenshot_id: SCREENSHOT_ID,
        from_x: { type: 'integer' },
        from_y: { type: 'integer' },
        to_x: { type: 'integer' },
        to_y: { type: 'integer' },
      },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    async execute(args, exec) {
      const result = await call(
        'drag',
        {
          window_id: args.window_id,
          screenshot_id: args.screenshot_id,
          from_x: args.from_x,
          from_y: args.from_y,
          to_x: args.to_x,
          to_y: args.to_y,
        },
        exec,
      )
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_set_value',
    description: '用 UI Automation 的 ValuePattern 直接把文本写入一个可编辑元素（比逐字输入稳定），元素编号来自最近一次 get_window_state。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id', 'element_index', 'value'],
      properties: {
        window_id: WINDOW_ID,
        element_index: { type: 'integer' },
        value: { type: 'string' },
      },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    async execute(args, exec) {
      const result = await call(
        'set_value',
        { window_id: args.window_id, element_index: args.element_index, value: args.value },
        exec,
      )
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_perform_secondary_action',
    description: '对元素执行次要无障碍动作：Expand / Collapse / Scroll Up / Scroll Down / Scroll Left / Scroll Right / Invoke（见元素树方括号里的能力）。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id', 'element_index', 'action'],
      properties: {
        window_id: WINDOW_ID,
        element_index: { type: 'integer' },
        action: { type: 'string' },
      },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    async execute(args, exec) {
      const result = await call(
        'perform_secondary_action',
        { window_id: args.window_id, element_index: args.element_index, action: args.action },
        exec,
      )
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_activate_window',
    description: '把窗口带到前台（还原并置顶）。键盘/坐标输入前如果窗口不在前台，helper 会自动做同样的事，所以通常只需要在切换目标时显式调用。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['window_id'],
      properties: { window_id: WINDOW_ID },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    async execute(args, exec) {
      const result = await call('activate_window', { window_id: args.window_id }, exec)
      return result ?? {}
    },
  })

  registerTool({
    name: 'computer_launch_app',
    description: '启动一个应用（可执行文件路径或系统能找到的名字），返回它新出现的窗口。应用已经在运行但没有窗口时，先试 computer_list_windows。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['app'],
      properties: { app: { type: 'string', description: '例如 notepad.exe 或完整的 .exe 路径。' } },
    },
    output: { schema: { type: 'object', additionalProperties: true, properties: {} }, render: (_a, v) => textOnly(v) },
    timeoutMs: 60_000,
    async execute(args, exec) {
      const result = await call('launch_app', { app: args.app }, exec, { timeoutMs: 30_000 })
      return result ?? {}
    },
  })

  // Model-facing operating manual, mirroring Qoder's skill.
  try {
    const content = readFileSync(SKILL_FILE, 'utf8')
    ctx.effect(
      () =>
        ctx.skills.register({
          name: SKILL_NAME,
          description: '用 DSH 的桌面控制工具操作 Windows 应用：观察窗口（截图 / 无障碍树）、元素或坐标点击、输入、快捷键、滚动、拖拽。',
          whenToUse: '当任务只能通过图形界面完成，或需要核对某个应用的真实界面时使用。',
          content,
          resourceBase: { kind: 'directory', path: path.dirname(SKILL_FILE) },
          invocation: { modelInvocable: true, userInvocable: true },
        }),
      'computer-use: skill',
    )
  } catch {
    /* a missing manual must not stop the tools */
  }
}
