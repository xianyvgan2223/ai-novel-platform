<!--
  RichText.vue —— 极简 Markdown 渲染
  只支持 AI 回复里真正常见的语法：加粗、行内代码、代码块、标题、列表、段落。
  正则中的 \u0060 就是反引号，这样写是为了不与源码里的模板字符串冲突。

  刻意不使用 v-html：全部走 VNode 渲染，数据里带 HTML 也不会被执行。
-->
<script setup lang="ts">
import { computed } from 'vue';

interface Inline {
  t: 'text' | 'bold' | 'code';
  v: string;
}

interface Block {
  k: 'p' | 'h' | 'code' | 'ul' | 'ol';
  lines?: Inline[][];
  text?: string;
  lang?: string;
  items?: Inline[][];
}

const props = defineProps<{ text: string }>();

/** 行内解析：加粗 与 行内代码 */
function parseInline(line: string): Inline[] {
  const out: Inline[] = [];
  const re = /(\*\*([^*]+)\*\*)|(\u0060([^\u0060]+)\u0060)/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(line)) !== null) {
    if (m.index > last) out.push({ t: 'text', v: line.slice(last, m.index) });
    if (m[2] !== undefined) out.push({ t: 'bold', v: m[2] });
    else if (m[4] !== undefined) out.push({ t: 'code', v: m[4] });
    last = m.index + m[0].length;
  }
  if (last < line.length) out.push({ t: 'text', v: line.slice(last) });
  return out.length ? out : [{ t: 'text', v: '' }];
}

const FENCE = /^\s*\u0060\u0060\u0060/;

function parseBlocks(src: string): Block[] {
  const lines = String(src ?? '').split(/\r?\n/);
  const blocks: Block[] = [];
  let para: Inline[][] = [];
  let list: { kind: 'ul' | 'ol'; items: Inline[][] } | null = null;
  let i = 0;

  const flushPara = () => {
    if (para.length) {
      blocks.push({ k: 'p', lines: para });
      para = [];
    }
  };
  const flushList = () => {
    if (!list) return;
    if (list.kind === 'ul') blocks.push({ k: 'ul', items: list.items });
    else blocks.push({ k: 'ol', items: list.items });
    list = null;
  };

  while (i < lines.length) {
    const line = lines[i];

    if (FENCE.test(line)) {
      flushPara();
      flushList();
      const lang = line.replace(FENCE, '').trim();
      const buf: string[] = [];
      i += 1;
      while (i < lines.length && !FENCE.test(lines[i])) {
        buf.push(lines[i]);
        i += 1;
      }
      i += 1;
      blocks.push({ k: 'code', lang, text: buf.join('\n') });
      continue;
    }

    if (!line.trim()) {
      flushPara();
      flushList();
      i += 1;
      continue;
    }

    const heading = /^(#{1,4})\s+(.*)$/.exec(line);
    if (heading) {
      flushPara();
      flushList();
      blocks.push({ k: 'h', text: heading[2] });
      i += 1;
      continue;
    }

    const bullet = /^\s*[-*]\s+(.*)$/.exec(line);
    if (bullet) {
      flushPara();
      if (!list || list.kind !== 'ul') {
        flushList();
        list = { kind: 'ul', items: [] };
      }
      list.items.push(parseInline(bullet[1]));
      i += 1;
      continue;
    }

    const ordered = /^\s*\d+[.)]\s+(.*)$/.exec(line);
    if (ordered) {
      flushPara();
      if (!list || list.kind !== 'ol') {
        flushList();
        list = { kind: 'ol', items: [] };
      }
      list.items.push(parseInline(ordered[1]));
      i += 1;
      continue;
    }

    flushList();
    para.push(parseInline(line));
    i += 1;
  }

  flushPara();
  flushList();
  return blocks;
}

const blocks = computed(() => parseBlocks(props.text));
</script>

<template>
  <div class="rt">
    <template v-for="(b, bi) in blocks" :key="bi">
      <pre v-if="b.k === 'code'" class="rt-code"><code>{{ b.text }}</code></pre>

      <h4 v-else-if="b.k === 'h'" class="rt-h">{{ b.text }}</h4>

      <ul v-else-if="b.k === 'ul'" class="rt-list">
        <li v-for="(it, ii) in b.items ?? []" :key="ii">
          <span v-for="(s, si) in it" :key="si">
            <strong v-if="s.t === 'bold'">{{ s.v }}</strong>
            <code v-else-if="s.t === 'code'" class="rt-inline">{{ s.v }}</code>
            <template v-else>{{ s.v }}</template>
          </span>
        </li>
      </ul>

      <ol v-else-if="b.k === 'ol'" class="rt-list rt-ordered">
        <li v-for="(it, ii) in b.items ?? []" :key="ii">
          <span v-for="(s, si) in it" :key="si">
            <strong v-if="s.t === 'bold'">{{ s.v }}</strong>
            <code v-else-if="s.t === 'code'" class="rt-inline">{{ s.v }}</code>
            <template v-else>{{ s.v }}</template>
          </span>
        </li>
      </ol>

      <p v-else class="rt-p">
        <template v-for="(line, li) in b.lines ?? []" :key="li">
          <br v-if="li > 0" />
          <span v-for="(s, si) in line" :key="si">
            <strong v-if="s.t === 'bold'">{{ s.v }}</strong>
            <code v-else-if="s.t === 'code'" class="rt-inline">{{ s.v }}</code>
            <template v-else>{{ s.v }}</template>
          </span>
        </template>
      </p>
    </template>
  </div>
</template>

<style scoped>
.rt { word-break: break-word; }
.rt > :first-child { margin-top: 0; }
.rt > :last-child { margin-bottom: 0; }

.rt-p { margin: 0 0 10px; }

.rt-h {
  margin: 14px 0 8px;
  font-size: 14px;
  font-weight: 650;
  color: var(--ink-1);
}

.rt-list { margin: 0 0 10px; padding-left: 20px; }
.rt-list li { margin-bottom: 4px; }
.rt-ordered { list-style: decimal; }
.rt-list li::marker { color: var(--ink-3); }

.rt-code {
  margin: 10px 0;
  padding: 12px 14px;
  background: #1a1a18;
  color: #f3efe6;
  border-radius: 8px;
  overflow: auto;
  font-family: 'JetBrains Mono', 'Cascadia Mono', Consolas, monospace;
  font-size: 12px;
  line-height: 1.7;
}

.rt-inline {
  padding: 1px 5px;
  border-radius: 4px;
  background: rgba(26, 26, 24, 0.06);
  font-family: 'JetBrains Mono', 'Cascadia Mono', Consolas, monospace;
  font-size: 0.92em;
  color: #6d5a4a;
}

strong { font-weight: 650; color: var(--ink-1); }
</style>
