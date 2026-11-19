<!--
  RichText.vue —— 轻量 Markdown 渲染

  覆盖 Agent / 聊天回复里常见的语法：标题、段落、加粗、斜体、删除线、
  行内代码、代码块、有序/无序列表、引用、表格、链接、分割线。
  刻意不使用 v-html：全部走 VNode 渲染，数据里带 HTML 也不会被执行。
-->
<script setup lang="ts">
import { computed } from 'vue';

import type { Align } from './markdown';
import { parseMarkdown } from './markdown';
import RichTextInline from './RichTextInline.vue';

const props = defineProps<{ text: string }>();

const blocks = computed(() => parseMarkdown(props.text));

function headingTag(level?: number): string {
  return `h${Math.min(Math.max(level ?? 4, 1), 4)}`;
}

function alignClass(align?: Align): string {
  return align ? `rt-align-${align}` : '';
}
</script>

<template>
  <div class="rt">
    <template v-for="(b, bi) in blocks" :key="bi">
      <pre
        v-if="b.k === 'code'"
        class="rt-code"
        :data-lang="b.lang || undefined"
      ><code>{{ b.text }}</code></pre>

      <component
        :is="headingTag(b.level)"
        v-else-if="b.k === 'h'"
        class="rt-h"
      >
        {{ b.text }}
      </component>

      <div v-else-if="b.k === 'table'" class="rt-table-wrap">
        <table class="rt-table">
          <thead>
            <tr>
              <th
                v-for="(cell, ci) in b.header ?? []"
                :key="ci"
                :class="alignClass(b.align?.[ci])"
              >
                <RichTextInline :items="cell" />
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(row, ri) in b.rows ?? []" :key="ri">
              <td
                v-for="(cell, ci) in row"
                :key="ci"
                :class="alignClass(b.align?.[ci])"
              >
                <RichTextInline :items="cell" />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <blockquote v-else-if="b.k === 'quote'" class="rt-quote">
        <p v-for="(line, li) in b.lines ?? []" :key="li">
          <RichTextInline :items="line" />
        </p>
      </blockquote>

      <hr v-else-if="b.k === 'hr'" class="rt-hr" />

      <ul v-else-if="b.k === 'ul'" class="rt-list">
        <li v-for="(it, ii) in b.items ?? []" :key="ii">
          <RichTextInline :items="it" />
        </li>
      </ul>

      <ol v-else-if="b.k === 'ol'" class="rt-list rt-ordered">
        <li v-for="(it, ii) in b.items ?? []" :key="ii">
          <RichTextInline :items="it" />
        </li>
      </ol>

      <p v-else class="rt-p">
        <template v-for="(line, li) in b.lines ?? []" :key="li">
          <br v-if="li > 0" />
          <RichTextInline :items="line" />
        </template>
      </p>
    </template>
  </div>
</template>

<style scoped>
.rt {
  word-break: break-word;
}
.rt > :first-child {
  margin-top: 0;
}
.rt > :last-child {
  margin-bottom: 0;
}

.rt-p {
  margin: 0 0 10px;
}

.rt-h {
  margin: 14px 0 8px;
  font-weight: 650;
  color: var(--ink-1);
}
.rt-h:is(h1) {
  font-size: 17px;
}
.rt-h:is(h2) {
  font-size: 15.5px;
}
.rt-h:is(h3) {
  font-size: 14px;
}
.rt-h:is(h4) {
  font-size: 13px;
}

.rt-list {
  margin: 0 0 10px;
  padding-left: 20px;
}
.rt-list li {
  margin-bottom: 4px;
}
.rt-ordered {
  list-style: decimal;
}
.rt-list li::marker {
  color: var(--ink-3);
}

.rt-code {
  position: relative;
  margin: 10px 0;
  padding: 12px 14px;
  background: var(--code-block-bg);
  color: var(--code-block-text);
  border-radius: 8px;
  overflow: auto;
  font-family: 'JetBrains Mono', 'Cascadia Mono', Consolas, monospace;
  font-size: 12px;
  line-height: 1.7;
}
.rt-code[data-lang]::before {
  content: attr(data-lang);
  position: absolute;
  top: 5px;
  right: 10px;
  color: var(--ink-4);
  font-size: 10px;
  line-height: 1;
  text-transform: lowercase;
}

.rt-table-wrap {
  margin: 10px 0;
  overflow-x: auto;
}
.rt-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12px;
  line-height: 1.6;
}
.rt-table th,
.rt-table td {
  padding: 6px 8px;
  border: 1px solid var(--line);
  vertical-align: top;
  text-align: left;
}
.rt-table th {
  background: var(--bg-soft);
  font-weight: 600;
  color: var(--ink-1);
}
.rt-table tr:nth-child(even) td {
  background: color-mix(in srgb, var(--bg-soft) 55%, transparent);
}
.rt-align-center {
  text-align: center;
}
.rt-align-right {
  text-align: right;
}
.rt-align-left {
  text-align: left;
}

.rt-quote {
  margin: 10px 0;
  padding: 6px 12px;
  border-left: 3px solid var(--brand);
  background: var(--bg-soft);
  border-radius: 0 6px 6px 0;
  color: var(--ink-2);
}
.rt-quote p {
  margin: 0;
}
.rt-quote p + p {
  margin-top: 4px;
}

.rt-hr {
  margin: 14px 0;
  border: 0;
  border-top: 1px solid var(--line);
}
</style>
