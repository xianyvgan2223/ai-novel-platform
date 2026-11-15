<!--
  AgentPanel.vue —— 右侧常驻 Agent 面板
  与左侧导航对称：可拖宽、可收起。对话里能看到每次工具调用的参数与返回，
  生成过程中可以点「停止」真正中断（前端 abort + 服务端取消）。
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue';
import { ArrowRight, ChatDotRound, Delete, Promotion, VideoPause } from '@element-plus/icons-vue';
import RichText from '@/components/RichText.vue';
import AgentToolCard from '@/components/agent/AgentToolCard.vue';
import { useAgentStore } from '@/stores/agent';
import type { AgentMessage, AgentTextPart } from '@/stores/agent';

const agent = useAgentStore();

const MIN_WIDTH = 300;
const MAX_WIDTH = 620;

const input = ref('');
const bodyRef = ref<HTMLElement | null>(null);
const resizing = ref(false);
const draftWidth = ref(agent.panelWidth);

let startX = 0;
let startWidth = 0;

const suggestions = [
  '现在库里有哪些数据？',
  '找几个适合做开篇的剧情素材',
  '按仙侠题材一键生成大纲',
  '列出我已有的大纲',
];

const shellStyle = computed(() => ({
  '--agent-width': draftWidth.value + 'px',
}));

const canSubmit = computed(() => agent.canSend && input.value.trim().length > 0);

function textOf(message: AgentMessage): string {
  return message.parts
    .filter((part): part is AgentTextPart => part.kind === 'text')
    .map((part) => part.text)
    .join('');
}

function submit(): void {
  const text = input.value.trim();
  if (!text || agent.streaming) return;
  input.value = '';
  void agent.send(text);
}

function useSuggestion(text: string): void {
  if (agent.streaming) return;
  input.value = text;
  submit();
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    submit();
  }
}

function scrollToBottom(): void {
  void nextTick(() => {
    const el = bodyRef.value;
    if (el) el.scrollTop = el.scrollHeight;
  });
}

watch(
  () => agent.messages,
  () => scrollToBottom(),
  { deep: true },
);

watch(
  () => agent.panelOpen,
  (open) => {
    if (open) {
      void agent.loadTools();
      scrollToBottom();
    }
  },
);

// ── 拖拽调宽（左侧边缘）──
function startResize(event: PointerEvent): void {
  event.preventDefault();
  resizing.value = true;
  startX = event.clientX;
  startWidth = draftWidth.value;
  window.addEventListener('pointermove', onResizeMove);
  window.addEventListener('pointerup', endResize, { once: true });
  window.addEventListener('pointercancel', endResize, { once: true });
}

function onResizeMove(event: PointerEvent): void {
  if (!resizing.value) return;
  const delta = event.clientX - startX;
  // 面板在右侧：往左拖 = 变宽
  draftWidth.value = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, Math.round(startWidth - delta)));
}

function endResize(): void {
  if (!resizing.value) return;
  resizing.value = false;
  window.removeEventListener('pointermove', onResizeMove);
  window.removeEventListener('pointercancel', endResize);
  agent.setWidth(draftWidth.value);
}

watch(
  () => agent.panelWidth,
  (value) => {
    if (!resizing.value) draftWidth.value = value;
  },
);

onMounted(() => {
  if (agent.panelOpen) void agent.loadTools();
});

onUnmounted(() => {
  window.removeEventListener('pointermove', onResizeMove);
  window.removeEventListener('pointercancel', endResize);
});
</script>

<template>
  <aside class="agent" :class="{ collapsed: !agent.panelOpen }" :style="shellStyle">
    <button
      v-if="!agent.panelOpen"
      class="agent-rail"
      type="button"
      title="打开 AI 助手"
      @click="agent.togglePanel()"
    >
      <el-icon><ChatDotRound /></el-icon>
      <span class="rail-text">AI 助手</span>
    </button>

    <template v-else>
      <div
        class="agent-resizer"
        role="separator"
        aria-orientation="vertical"
        aria-label="拖动调整助手宽度"
        @pointerdown="startResize"
      />

      <header class="agent-head">
        <div class="agent-title">
          <span class="agent-dot" :class="{ busy: agent.streaming }" />
          <span class="agent-name">AI 助手</span>
          <span v-if="agent.streaming" class="agent-state">执行中</span>
        </div>
        <div class="agent-actions">
          <el-tooltip content="清空对话" placement="bottom">
            <el-button text circle :icon="Delete" @click="agent.clear()" />
          </el-tooltip>
          <el-tooltip content="收起面板" placement="bottom">
            <el-button text circle :icon="ArrowRight" @click="agent.togglePanel()" />
          </el-tooltip>
        </div>
      </header>

      <div ref="bodyRef" class="agent-body">
        <div v-if="!agent.hasMessages" class="agent-empty">
          <div class="empty-title">可以帮你做什么</div>
          <div class="empty-sub">查数据、找素材、生成大纲与正文，每次工具调用都会展示参数和返回。</div>
          <div class="empty-actions">
            <button
              v-for="item in suggestions"
              :key="item"
              class="suggestion"
              type="button"
              @click="useSuggestion(item)"
            >
              {{ item }}
            </button>
          </div>
          <div v-if="agent.tools.length" class="empty-tools">
            <span class="empty-tools-label">可用工具</span>
            <span v-for="tool in agent.tools" :key="tool.name" class="tool-chip" :title="tool.description">
              {{ tool.name }}
            </span>
          </div>
        </div>

        <div
          v-for="message in agent.messages"
          :key="message.id"
          class="msg"
          :class="message.role"
        >
          <template v-if="message.role === 'user'">
            <div class="bubble user">{{ textOf(message) }}</div>
          </template>

          <template v-else>
            <div class="bubble assistant">
              <template v-for="(part, index) in message.parts" :key="index">
                <RichText v-if="part.kind === 'text'" :text="part.text" />
                <AgentToolCard v-else :part="part" />
              </template>

              <div v-if="message.status === 'streaming' && !message.parts.length" class="typing">
                正在思考…
              </div>
              <div v-if="message.status === 'cancelled'" class="msg-note">已停止生成</div>
              <div v-if="message.status === 'error'" class="msg-note error">{{ message.error }}</div>
            </div>
          </template>
        </div>
      </div>

      <footer class="agent-foot">
        <textarea
          v-model="input"
          class="agent-input"
          rows="2"
          placeholder="问问数据、找素材，或让它生成大纲…（Enter 发送，Shift+Enter 换行）"
          @keydown="onKeydown"
        />
        <div class="agent-foot-row">
          <span class="agent-hint">只读 · 生成结果不会自动保存</span>
          <el-button
            v-if="agent.streaming"
            type="danger"
            plain
            size="small"
            :icon="VideoPause"
            @click="agent.stop()"
          >
            停止
          </el-button>
          <el-button
            v-else
            type="primary"
            size="small"
            :icon="Promotion"
            :disabled="!canSubmit"
            @click="submit"
          >
            发送
          </el-button>
        </div>
      </footer>
    </template>
  </aside>
</template>

<style scoped>
.agent {
  position: relative;
  width: var(--agent-width, 380px);
  flex: 0 0 var(--agent-width, 380px);
  min-height: 0;
  display: flex;
  flex-direction: column;
  background: var(--bg-card);
  border-left: 1px solid var(--line);
}

.agent.collapsed {
  width: 46px;
  flex-basis: 46px;
}

.agent-resizer {
  position: absolute;
  top: 0;
  left: -4px;
  width: 8px;
  height: 100%;
  z-index: 20;
  cursor: col-resize;
}

.agent-resizer::after {
  content: '';
  position: absolute;
  top: 0;
  bottom: 0;
  left: 3px;
  width: 1px;
  background: transparent;
  transition: background 0.15s ease;
}

.agent-resizer:hover::after {
  background: var(--ink-3);
}

.agent-rail {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  width: 100%;
  height: 100%;
  padding: 16px 0;
  border: none;
  background: transparent;
  color: var(--ink-2);
  cursor: pointer;
}

.agent-rail:hover {
  background: var(--bg-soft);
}

.rail-text {
  writing-mode: vertical-rl;
  font-size: 11px;
  letter-spacing: 2px;
  color: var(--ink-3);
}

.agent-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  height: 48px;
  flex: 0 0 48px;
  padding: 0 8px 0 14px;
  border-bottom: 1px solid var(--line);
}

.agent-title {
  display: flex;
  align-items: center;
  gap: 7px;
  min-width: 0;
}

.agent-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--ok);
  flex: 0 0 7px;
}

.agent-dot.busy {
  background: var(--warning);
  animation: agent-pulse 1.1s ease-in-out infinite;
}

@keyframes agent-pulse {
  50% {
    opacity: 0.35;
  }
}

.agent-name {
  font-size: 13px;
  font-weight: 600;
  color: var(--ink-1);
}

.agent-state {
  font-size: 10.5px;
  color: var(--ink-3);
}

.agent-actions {
  display: flex;
  align-items: center;
  gap: 2px;
}

.agent-body {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.agent-empty {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.empty-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--ink-1);
}

.empty-sub {
  font-size: 11.5px;
  line-height: 1.65;
  color: var(--ink-3);
}

.empty-actions {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-top: 2px;
}

.suggestion {
  width: 100%;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 7px;
  background: var(--bg-soft);
  color: var(--ink-2);
  font-size: 11.5px;
  text-align: left;
  cursor: pointer;
  transition: border-color 0.15s ease, color 0.15s ease;
}

.suggestion:hover {
  border-color: var(--control-border);
  color: var(--ink-1);
}

.empty-tools {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 5px;
  margin-top: 4px;
}

.empty-tools-label {
  font-size: 10.5px;
  color: var(--ink-4);
}

.tool-chip {
  padding: 1px 6px;
  border-radius: 4px;
  border: 1px solid var(--line-strong);
  font-size: 10px;
  color: var(--ink-3);
}

.msg {
  display: flex;
  flex-direction: column;
}

.msg.user {
  align-items: flex-end;
}

.bubble.user {
  max-width: 90%;
  padding: 8px 11px;
  border-radius: 10px 10px 2px 10px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  font-size: 12.5px;
  line-height: 1.6;
  color: var(--ink-1);
  white-space: pre-wrap;
  word-break: break-word;
}

.bubble.assistant {
  display: flex;
  flex-direction: column;
  gap: 8px;
  font-size: 12.5px;
  line-height: 1.7;
  color: var(--ink-1);
  word-break: break-word;
}

.typing {
  font-size: 11.5px;
  color: var(--ink-3);
}

.msg-note {
  font-size: 10.5px;
  color: var(--ink-4);
}

.msg-note.error {
  color: var(--danger);
}

.agent-foot {
  flex: 0 0 auto;
  padding: 10px 12px 12px;
  border-top: 1px solid var(--line);
}

.agent-input {
  width: 100%;
  box-sizing: border-box;
  resize: none;
  padding: 8px 10px;
  border: 1px solid var(--control-border);
  border-radius: 7px;
  background: var(--bg-soft);
  color: var(--ink-1);
  font-family: inherit;
  font-size: 12.5px;
  line-height: 1.6;
  outline: none;
}

.agent-input:focus {
  border-color: var(--ink-3);
}

.agent-foot-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-top: 8px;
}

.agent-hint {
  font-size: 10px;
  color: var(--ink-4);
}

@media (max-width: 960px) {
  .agent {
    position: fixed;
    top: 0;
    right: 0;
    bottom: 0;
    z-index: 60;
    width: min(92vw, 420px);
    flex-basis: auto;
    box-shadow: var(--shadow-card);
  }

  .agent.collapsed {
    width: 46px;
    flex-basis: 46px;
  }

  .agent-resizer {
    display: none;
  }
}
</style>
