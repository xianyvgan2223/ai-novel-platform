<!--
  AgentPanel.vue —— 右侧常驻 Agent 面板
  支持：新对话、历史会话、模型设置（仅影响本面板）、多步任务清单、
  工具调用可见、生成中途真正中断。
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { ArrowRight, ChatDotRound, Delete, Plus, Promotion, Setting, VideoPause } from '@element-plus/icons-vue';
import RichText from '@/components/RichText.vue';
import AgentToolCard from '@/components/agent/AgentToolCard.vue';
import AgentTaskCard from '@/components/agent/AgentTaskCard.vue';
import AgentAskCard from '@/components/agent/AgentAskCard.vue';
import { formatTime } from '@/api';
import { useAgentStore } from '@/stores/agent';
import type { AgentAskPart, AgentMessage, AgentTextPart } from '@/stores/agent';
import type { AgentSettings } from '@/api/agent';

const agent = useAgentStore();

const MIN_WIDTH = 300;
const MAX_WIDTH = 620;

const input = ref('');
const bodyRef = ref<HTMLElement | null>(null);
const resizing = ref(false);
const draftWidth = ref(agent.panelWidth);
const historyOpen = ref(false);
const settingsOpen = ref(false);
const saving = ref(false);

let startX = 0;
let startWidth = 0;

const suggestions = [
  '现在库里有哪些数据？',
  '找几个适合做开篇的剧情素材',
  '按仙侠题材一键生成大纲',
  '帮我检查已有大纲有没有设定冲突，分步骤做',
];

const form = ref({
  apiKey: '',
  baseUrl: '',
  model: '',
  temperature: undefined as number | undefined,
  maxTokens: undefined as number | undefined,
  topP: undefined as number | undefined,
  frequencyPenalty: undefined as number | undefined,
  presencePenalty: undefined as number | undefined,
  systemPrompt: '',
  webSearch: false,
  searchCount: 5,
  searchNeedContent: false,
});

const shellStyle = computed(() => ({
  '--agent-width': draftWidth.value + 'px',
}));

const canSubmit = computed(() => agent.canSend && input.value.trim().length > 0);
const hasApiKey = computed(() => Boolean(agent.settings?.hasApiKey));
const maskedKey = computed(() => agent.settings?.apiKey || '');
const defaultBaseUrl = computed(() => agent.settings?.defaults?.baseUrl || 'https://api.deepseek.com');
const defaultModel = computed(() => agent.settings?.defaults?.model || 'deepseek-chat');

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
      void agent.loadSessions();
      void agent.resumeActive();
      scrollToBottom();
    }
  },
);

// ── 会话 ──
async function openSession(id: number): Promise<void> {
  historyOpen.value = false;
  try {
    await agent.openSession(id);
    scrollToBottom();
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : String(error));
  }
}

async function removeSession(id: number): Promise<void> {
  try {
    await ElMessageBox.confirm('删除这个对话及其消息？该操作不可撤销。', '删除对话', {
      type: 'warning',
      confirmButtonText: '删除',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  try {
    await agent.deleteSession(id);
    ElMessage.success('已删除');
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : String(error));
  }
}

// ── 设置 ──
async function openSettings(): Promise<void> {
  await agent.loadSettings();
  const settings = agent.settings;
  const target = form.value;
  target.apiKey = '';
  target.baseUrl = settings?.baseUrl || settings?.defaults?.baseUrl || '';
  target.model = settings?.model || settings?.defaults?.model || '';
  target.temperature = settings?.temperature ?? undefined;
  target.maxTokens = settings?.maxTokens ?? undefined;
  target.topP = settings?.topP ?? undefined;
  target.frequencyPenalty = settings?.frequencyPenalty ?? undefined;
  target.presencePenalty = settings?.presencePenalty ?? undefined;
  target.systemPrompt = settings?.systemPrompt ?? '';
  target.webSearch = Boolean(settings?.webSearch);
  target.searchCount = settings?.searchCount ?? 5;
  target.searchNeedContent = Boolean(settings?.searchNeedContent);
  settingsOpen.value = true;
}

async function saveSettings(): Promise<void> {
  saving.value = true;
  try {
    const target = form.value;
    const payload: Partial<AgentSettings> = {
      apiKey: target.apiKey,
      baseUrl: target.baseUrl,
      model: target.model,
      temperature: target.temperature ?? null,
      maxTokens: target.maxTokens ?? null,
      topP: target.topP ?? null,
      frequencyPenalty: target.frequencyPenalty ?? null,
      presencePenalty: target.presencePenalty ?? null,
      systemPrompt: target.systemPrompt,
      webSearch: target.webSearch,
      searchCount: target.searchCount,
      searchNeedContent: target.searchNeedContent,
    };
    await agent.saveSettings(payload);
    settingsOpen.value = false;
    ElMessage.success('设置已保存');
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : String(error));
  } finally {
    saving.value = false;
  }
}

async function answerAsk(part: AgentAskPart, value: string): Promise<void> {
  try {
    await agent.answerAsk(part, value);
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : String(error));
  }
}

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
  if (agent.panelOpen) {
    void agent.loadTools();
    void agent.loadSessions();
    void agent.resumeActive();
  }
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
        <el-popover
          v-model:visible="historyOpen"
          placement="bottom-start"
          :width="300"
          trigger="click"
          :teleported="false"
        >
          <template #reference>
            <button class="session-btn" type="button" :disabled="agent.streaming">
              <span class="agent-dot" :class="{ busy: agent.streaming }" />
              <span class="session-title">{{ agent.currentTitle || '新对话' }}</span>
              <span class="session-caret">▾</span>
            </button>
          </template>

          <div class="history">
            <div class="history-head">
              <span class="history-head-title">历史对话</span>
              <button class="history-refresh" type="button" @click="agent.loadSessions()">刷新</button>
            </div>
            <div class="history-list">
              <button
                v-for="item in agent.sessions"
                :key="item.id"
                class="history-item"
                :class="{ on: item.id === agent.currentSessionId }"
                type="button"
                @click="openSession(item.id)"
              >
                <span class="history-title">{{ item.title || '新对话' }}</span>
                <span class="history-meta">{{ item.messageCount }} 条 · {{ formatTime(item.updatedAt) }}</span>
                <el-icon class="history-del" title="删除对话" @click.stop="removeSession(item.id)">
                  <Delete />
                </el-icon>
              </button>
              <div v-if="!agent.sessions.length" class="history-empty">还没有历史对话</div>
            </div>
          </div>
        </el-popover>

        <div class="agent-actions">
          <span v-if="agent.streaming" class="agent-state">执行中</span>
          <el-tooltip content="新对话" placement="bottom">
            <el-button text circle :icon="Plus" :disabled="agent.streaming" @click="agent.newSession()" />
          </el-tooltip>
          <el-tooltip content="模型设置（只影响本面板）" placement="bottom">
            <el-button text circle :icon="Setting" @click="openSettings" />
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
                <AgentAskCard
                  v-else-if="part.kind === 'ask'"
                  :part="part"
                  @answer="(value) => answerAsk(part, value)"
                />
                <AgentToolCard v-else :part="part" />
              </template>

              <div v-if="message.status === 'streaming' && !message.parts.length" class="typing">
                正在思考…
              </div>
              <div v-if="message.status === 'cancelled'" class="msg-note">已停止生成</div>
              <div v-if="message.status === 'interrupted'" class="msg-note">
                任务因服务重启中断，发送「继续」可以接着做
              </div>
              <div v-if="message.status === 'error'" class="msg-note error">{{ message.error }}</div>
            </div>
          </template>
        </div>
      </div>

      <AgentTaskCard v-if="agent.activeTask" :task="agent.activeTask" />

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

    <el-dialog v-model="settingsOpen" title="Agent 设置" width="460px" :teleported="false">
      <el-form label-width="92px" size="small" class="settings-form">
        <el-form-item label="API Key">
          <el-input
            v-model="form.apiKey"
            show-password
            :placeholder="hasApiKey ? '已配置，留空则不修改' : 'sk-...'"
          />
          <div v-if="hasApiKey" class="form-hint mono">当前：{{ maskedKey }}</div>
        </el-form-item>
        <el-form-item label="Base URL">
          <el-input v-model="form.baseUrl" :placeholder="defaultBaseUrl" />
        </el-form-item>
        <el-form-item label="模型">
          <el-input v-model="form.model" :placeholder="defaultModel" />
        </el-form-item>
        <el-form-item label="Temperature">
          <el-input-number v-model="form.temperature" :min="0" :max="2" :step="0.1" controls-position="right" />
        </el-form-item>
        <el-form-item label="Max Tokens">
          <el-input-number v-model="form.maxTokens" :min="256" :max="32768" :step="256" controls-position="right" />
        </el-form-item>
        <el-form-item label="Top P">
          <el-input-number v-model="form.topP" :min="0" :max="1" :step="0.05" controls-position="right" />
        </el-form-item>
        <el-form-item label="频率惩罚">
          <el-input-number
            v-model="form.frequencyPenalty"
            :min="-2"
            :max="2"
            :step="0.1"
            controls-position="right"
          />
        </el-form-item>
        <el-form-item label="存在惩罚">
          <el-input-number
            v-model="form.presencePenalty"
            :min="-2"
            :max="2"
            :step="0.1"
            controls-position="right"
          />
        </el-form-item>
        <el-form-item label="追加提示词">
          <el-input
            v-model="form.systemPrompt"
            type="textarea"
            :rows="3"
            placeholder="会追加到系统提示词后面，例如「回答尽量简短」"
          />
        </el-form-item>
        <el-form-item label="联网搜索">
          <el-switch v-model="form.webSearch" />
          <span class="form-hint inline">开启后 Agent 可调用 web_search</span>
        </el-form-item>
        <template v-if="form.webSearch">
          <el-form-item label="搜索条数">
            <el-input-number
              v-model="form.searchCount"
              :min="1"
              :max="20"
              :step="1"
              controls-position="right"
            />
          </el-form-item>
          <el-form-item label="抓取正文">
            <el-switch v-model="form.searchNeedContent" />
            <span class="form-hint inline">开启后返回网页正文，上下文消耗更大</span>
          </el-form-item>
        </template>
      </el-form>
      <template #footer>
        <el-button @click="settingsOpen = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="saveSettings">保存</el-button>
      </template>
    </el-dialog>
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
  padding: 0 8px 0 10px;
  border-bottom: 1px solid var(--line);
}

.session-btn {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  padding: 5px 8px;
  border: 1px solid transparent;
  border-radius: 7px;
  background: transparent;
  color: var(--ink-1);
  cursor: pointer;
}

.session-btn:hover {
  background: var(--bg-soft);
  box-shadow: var(--shadow-control);
}

.session-btn:disabled {
  opacity: 0.6;
  cursor: default;
}

.session-title {
  max-width: 170px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13px;
  font-weight: 600;
}

.session-caret {
  font-size: 10px;
  color: var(--ink-4);
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

.agent-state {
  font-size: 10.5px;
  color: var(--ink-3);
  margin-right: 2px;
}

.agent-actions {
  display: flex;
  align-items: center;
  gap: 2px;
  flex: 0 0 auto;
}

/* ── 历史会话弹层 ── */
.history-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-bottom: 6px;
  border-bottom: 1px solid var(--line);
}

.history-head-title {
  font-size: 12px;
  font-weight: 600;
  color: var(--ink-1);
}

.history-refresh {
  border: none;
  background: transparent;
  color: var(--ink-3);
  font-size: 11px;
  cursor: pointer;
}

.history-refresh:hover {
  color: var(--ink-1);
}

.history-list {
  max-height: 320px;
  overflow-y: auto;
  margin-top: 6px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.history-item {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 2px;
  width: 100%;
  padding: 7px 26px 7px 8px;
  border: 1px solid transparent;
  border-radius: 6px;
  background: transparent;
  text-align: left;
  cursor: pointer;
}

.history-item:hover {
  background: var(--bg-soft);
}

.history-item.on {
  background: var(--bg-soft);
  box-shadow: var(--shadow-control);
}

.history-title {
  font-size: 12px;
  color: var(--ink-1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.history-meta {
  font-size: 10.5px;
  color: var(--ink-4);
}

.history-del {
  position: absolute;
  right: 6px;
  top: 50%;
  transform: translateY(-50%);
  font-size: 12px;
  color: var(--ink-4);
}

.history-del:hover {
  color: var(--danger);
}

.history-empty {
  padding: 18px 8px;
  text-align: center;
  font-size: 11.5px;
  color: var(--ink-4);
}

/* ── 消息区 ── */
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
  border: none;
  border-radius: 7px;
  background: var(--bg-soft);
  color: var(--ink-2);
  font-size: 11.5px;
  text-align: left;
  cursor: pointer;
  box-shadow: var(--shadow-control);
  transition: box-shadow 0.15s ease, color 0.15s ease;
}

.suggestion:hover {
  color: var(--ink-1);
  box-shadow: var(--shadow-card);
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
  box-shadow: var(--shadow-control);
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

/* ── 输入区 ── */
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
  border: none;
  border-radius: 7px;
  background: var(--bg-soft);
  color: var(--ink-1);
  font-family: inherit;
  font-size: 12.5px;
  line-height: 1.6;
  outline: none;
  box-shadow: var(--shadow-control);
  transition: box-shadow 0.15s ease;
}

.agent-input:focus {
  box-shadow: var(--shadow-card);
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

/* ── 设置弹窗 ── */
.settings-form {
  padding-right: 6px;
  max-height: 60vh;
  overflow-y: auto;
}

.form-hint {
  margin-top: 2px;
  font-size: 10.5px;
  color: var(--ink-4);
}

.form-hint.inline {
  margin: 0 0 0 8px;
  line-height: 1.4;
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
