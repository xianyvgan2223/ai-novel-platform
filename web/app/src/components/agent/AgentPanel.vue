<!--
  AgentPanel.vue —— 右侧常驻 Agent 面板
  支持：新对话、历史会话、模型设置（仅影响本面板）、多步任务清单、
  工具调用可见、生成中途真正中断。
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { ArrowRight, ChatDotRound, Delete, Download, Plus, Promotion, Setting, VideoPause } from '@element-plus/icons-vue';
import RichText from '@/components/RichText.vue';
import AgentToolCard from '@/components/agent/AgentToolCard.vue';
import AgentTaskCard from '@/components/agent/AgentTaskCard.vue';
import AgentAskCard from '@/components/agent/AgentAskCard.vue';
import AgentThinking from '@/components/agent/AgentThinking.vue';
import AgentDownloadList from '@/components/agent/AgentDownloadList.vue';
import SettingLabel from '@/components/agent/SettingLabel.vue';
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
const downloadsOpen = ref(false);
const downloadsLoading = ref(false);
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
  model: 'deepseek-flash',
  temperature: 1 as number | undefined,
  maxTokens: 32768 as number | undefined,
  topP: undefined as number | undefined,
  frequencyPenalty: undefined as number | undefined,
  presencePenalty: undefined as number | undefined,
  systemPrompt: '',
  webSearch: false,
  searchCount: 5,
  searchNeedContent: false,
  stream: true,
  thinking: true,
  reasoningEffort: 'high',
  contextWindow: 0,
});

const shellStyle = computed(() => ({
  '--agent-width': draftWidth.value + 'px',
}));

const canSubmit = computed(() => agent.canSend && input.value.trim().length > 0);
const hasApiKey = computed(() => Boolean(agent.settings?.hasApiKey));
const maskedKey = computed(() => agent.settings?.apiKey || '');
const defaultBaseUrl = computed(() => agent.settings?.defaults?.baseUrl || 'https://api.deepseek.com');
const defaultModel = computed(() => agent.settings?.defaults?.model || 'deepseek-flash');
const modelOptions = computed(
  () =>
    agent.settings?.modelOptions ?? [
      { id: 'deepseek-flash', label: 'DeepSeek Flash', description: '响应更快，适合日常对话与快速生成' },
      { id: 'deepseek-v4-pro', label: 'DeepSeek Pro', description: '推理更强，适合复杂任务与长文创作' },
    ],
);
const downloadItems = computed(() => agent.downloads);
const reasoningEfforts = computed(() => agent.settings?.reasoningEfforts ?? ['none', 'low', 'high', 'max']);

/** 上下文占用展示：百分比来自服务端，窗口为 0 时先不显示进度条 */
const ctxPercent = computed(() => {
  const window = agent.context.window || 0;
  if (window <= 0) return 0;
  const tokens = Math.max(0, agent.context.tokens || 0);
  return Math.min(100, (tokens * 100) / window);
});
/** 1M 窗口下 3k tokens 只有 0.3%，取一位小数才看得出变化 */
const ctxPercentText = computed(() =>
  ctxPercent.value > 0 && ctxPercent.value < 10 ? ctxPercent.value.toFixed(1) : String(Math.round(ctxPercent.value)),
);
const ctxBarWidth = computed(() => (ctxPercent.value > 0 ? Math.max(ctxPercent.value, 0.6) : 0));
const ctxWindow = computed(() => agent.context.window || 0);
const ctxTone = computed(() => (ctxPercent.value >= 90 ? 'danger' : ctxPercent.value >= 75 ? 'warn' : 'ok'));

/** 整体缓存命中率：本会话 Σ命中 / Σ输入（不是最近一次请求） */
const cacheRate = computed<number | null>(() => {
  const totalPrompt = agent.context.totalPromptTokens;
  if (totalPrompt <= 0) return null;
  return Math.min(
    100,
    Math.round((agent.context.totalCachedTokens * 1000) / totalPrompt) / 10,
  );
});
const cacheText = computed(() => (cacheRate.value === null ? '缓存 —' : `缓存 ${cacheRate.value}%`));
const cacheTooltip = computed(() => {
  if (agent.context.totalPromptTokens <= 0) return '本会话还没有可统计的用量（旧会话不回溯）';
  const parts = [
    `累计命中 ${formatTokens(agent.context.totalCachedTokens)} / 累计输入 ${formatTokens(agent.context.totalPromptTokens)}`,
  ];
  const usage = agent.context.lastUsage;
  if (usage) {
    parts.push(`最近一次 ${formatTokens(usage.cachedTokens)} / ${formatTokens(usage.promptTokens)}`);
  }
  return parts.join(' · ');
});

const ctxSummary = computed(() => {
  const usage = agent.context.lastUsage;
  const parts = [`占用 ${ctxPercentText.value}%`];
  if (ctxWindow.value > 0) {
    parts.push(`${formatTokens(agent.context.tokens)} / ${formatTokens(ctxWindow.value)}`);
  }
  if (agent.context.threshold > 0) {
    parts.push(`压缩阈值 ${formatTokens(agent.context.threshold)}`);
  }
  if (usage) {
    parts.push(`输入 ${formatTokens(usage.promptTokens)} · 输出 ${formatTokens(usage.completionTokens)}`);
    if (usage.cachedTokens > 0) parts.push(`最近一次缓存命中 ${formatTokens(usage.cachedTokens)}`);
  }
  if (agent.context.totalPromptTokens > 0) {
    parts.push(
      `累计缓存命中 ${formatTokens(agent.context.totalCachedTokens)} / ${formatTokens(agent.context.totalPromptTokens)}`,
    );
  }
  return parts.join(' · ');
});

/** 1.2M / 850k / 900 这类紧凑写法 */
function formatTokens(value: number): string {
  const n = Number(value) || 0;
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1) + 'M';
  if (n >= 1_000) return (n / 1_000).toFixed(n >= 100_000 ? 0 : 1) + 'k';
  return String(n);
}

async function compactHistory(): Promise<void> {
  try {
    const result = await agent.compactNow();
    if (!result) return;
    if (result.count > 0) {
      ElMessage.success(`已压缩 ${result.count} 条历史，释放约 ${formatTokens(result.freedTokens)} tokens`);
    } else {
      ElMessage.info('当前历史还不需要压缩');
    }
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : String(error));
  }
}

function effortLabel(effort: string): string {
  switch (effort) {
    case 'none':
      return 'none（不思考）';
    case 'low':
      return 'low（浅）';
    case 'max':
      return 'max（最深）';
    default:
      return 'high（标准）';
  }
}

function textOf(message: AgentMessage): string {
  return message.parts
    .filter((part): part is AgentTextPart => part.kind === 'text')
    .map((part) => part.text)
    .join('');
}

/** 单条回答的缓存命中率：cachedTokens / promptTokens（0-100，一位小数） */
function messageCacheRate(message: AgentMessage): number | null {
  const usage = message.usage;
  if (!usage || usage.promptTokens <= 0) return null;
  return Math.min(100, Math.round((usage.cachedTokens * 1000) / usage.promptTokens) / 10);
}

function messageCachePercent(message: AgentMessage): string {
  const rate = messageCacheRate(message);
  return rate === null ? '—' : String(rate);
}

function messageCacheTip(message: AgentMessage): string {
  const usage = message.usage;
  if (!usage) return '';
  return (
    `本次请求：缓存命中 ${formatTokens(usage.cachedTokens)} / 输入 ${formatTokens(usage.promptTokens)}` +
    ` · 输出 ${formatTokens(usage.completionTokens)}`
  );
}

function submit(): void {
  const text = input.value.trim();
  if (!text || agent.streaming) return;
  input.value = '';
  void agent.send(text);
  // 用户自己发消息：无论之前滚到哪里都拉回底部看回复
  scrollToBottom(true);
}

function useSuggestion(text: string): void {
  if (agent.streaming) return;
  input.value = text;
  submit();
}

function onKeydown(event: KeyboardEvent): void {
  // 中文输入法组字时按回车只是上屏，不能当成发送
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    submit();
  }
}

const NEAR_BOTTOM_GAP = 80;
const nearBottom = ref(true);

/** 记录用户是否停在底部附近：只有这时才自动滚动，避免打断上翻阅读 */
function onScroll(): void {
  const el = bodyRef.value;
  if (!el) return;
  nearBottom.value = el.scrollHeight - el.scrollTop - el.clientHeight < NEAR_BOTTOM_GAP;
}

/** force=true 用于发送、切换会话等必须看到最新内容的场景 */
function scrollToBottom(force = false): void {
  if (!force && !nearBottom.value) return;
  void nextTick(() => {
    const el = bodyRef.value;
    if (el) el.scrollTop = el.scrollHeight;
  });
}

// 流式输出用 lastSeq（每个事件都会变）当滚动信号，避免每个 token 深遍历整棵消息树
watch(
  () => agent.lastSeq,
  () => scrollToBottom(),
);

// 消息条数变化覆盖发送消息、切换会话等不产生事件的情况
watch(
  () => agent.messages.length,
  () => scrollToBottom(),
);

watch(
  () => agent.panelOpen,
  (open) => {
    if (open) {
      void agent.loadTools();
      void agent.loadSessions();
      void agent.resumeActive();
      scrollToBottom(true);
    }
  },
);

// ── 会话 ──
async function openSession(id: number): Promise<void> {
  historyOpen.value = false;
  try {
    await agent.openSession(id);
    // 切换会话后直接定位到最新消息
    scrollToBottom(true);
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
  target.model = settings?.model || settings?.defaults?.model || 'deepseek-flash';
  target.temperature = settings?.temperature ?? settings?.defaults?.temperature ?? 1;
  target.maxTokens = settings?.maxTokens ?? settings?.defaults?.maxTokens ?? 32768;
  target.topP = settings?.topP ?? undefined;
  target.frequencyPenalty = settings?.frequencyPenalty ?? undefined;
  target.presencePenalty = settings?.presencePenalty ?? undefined;
  target.systemPrompt = settings?.systemPrompt ?? '';
  target.webSearch = Boolean(settings?.webSearch);
  target.searchCount = settings?.searchCount ?? settings?.defaults?.searchCount ?? 5;
  target.searchNeedContent = Boolean(settings?.searchNeedContent);
  target.stream = settings?.stream ?? settings?.defaults?.stream ?? true;
  target.thinking = settings?.thinking ?? settings?.defaults?.thinking ?? true;
  target.reasoningEffort =
    settings?.reasoningEffort ?? settings?.defaults?.reasoningEffort ?? 'high';
  target.contextWindow = settings?.contextWindow ?? settings?.defaults?.contextWindow ?? 0;
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
      stream: target.stream,
      thinking: target.thinking,
      reasoningEffort: target.reasoningEffort,
      contextWindow: target.contextWindow,
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

async function answerAsk(
  part: AgentAskPart,
  value: string,
  done?: (ok: boolean) => void,
): Promise<void> {
  try {
    await agent.answerAsk(part, value);
    done?.(true);
  } catch (error) {
    done?.(false);
    ElMessage.error(error instanceof Error ? error.message : String(error));
  }
}

async function openDownloads(): Promise<void> {
  downloadsOpen.value = true;
  downloadsLoading.value = true;
  try {
    await agent.loadDownloads();
  } catch (error) {
    // 下载库加载失败不再静默，明确提示用户
    ElMessage.error(error instanceof Error ? error.message : String(error));
  } finally {
    downloadsLoading.value = false;
  }
}

async function refreshDownloads(): Promise<void> {
  try {
    await agent.loadDownloads();
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : String(error));
  }
}

async function removeDownload(id: number): Promise<void> {
  try {
    await agent.deleteDownload(id);
    ElMessage.success('已删除');
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
          <el-tooltip content="下载库" placement="bottom">
            <el-button text circle :icon="Download" @click="openDownloads" />
          </el-tooltip>
          <el-tooltip content="模型设置（只影响本面板）" placement="bottom">
            <el-button text circle :icon="Setting" @click="openSettings" />
          </el-tooltip>
          <el-tooltip content="收起面板" placement="bottom">
            <el-button text circle :icon="ArrowRight" @click="agent.togglePanel()" />
          </el-tooltip>
        </div>
      </header>

      <div v-if="agent.lastError" class="agent-error">
        <span class="agent-error-text">{{ agent.lastError }}</span>
      </div>

      <div ref="bodyRef" class="agent-body" @scroll="onScroll">
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
                <AgentThinking
                  v-else-if="part.kind === 'thinking'"
                  :text="part.text"
                  :streaming="message.status === 'streaming' && index === message.parts.length - 1"
                />
                <AgentAskCard
                  v-else-if="part.kind === 'ask'"
                  :part="part"
                  @answer="(value, done) => answerAsk(part, value, done)"
                />
                <AgentToolCard v-else :part="part" />
              </template>

              <div v-if="message.status === 'streaming' && !message.parts.length" class="typing">
                正在思考…
              </div>
              <div v-if="message.status === 'cancelled'" class="msg-note">已停止生成</div>
              <div v-if="message.status === 'interrupted'" class="msg-note">
                {{ message.error || '任务因服务重启中断，发送「继续」可以接着做' }}
              </div>
              <!-- 当前运行的错误详情统一在顶部错误条展示，避免同一条错误出现两次；历史消息的错误跟随气泡 -->
              <div v-if="message.status === 'error'" class="msg-note error">
                {{ (message.fromHistory && message.error) || '生成失败' }}
              </div>
            </div>
            <!-- 这条回答自己的缓存命中（最后一次模型请求），与会话累计值区分开 -->
            <div
              v-if="message.status !== 'streaming' && message.usage"
              class="msg-cache"
              :class="{ good: (messageCacheRate(message) ?? 0) >= 60 }"
              :title="messageCacheTip(message)"
            >
              <span class="msg-cache-dot"></span>
              缓存命中 {{ messageCachePercent(message) }}%
              <span class="msg-cache-tokens">
                {{ formatTokens(message.usage.cachedTokens) }} / {{ formatTokens(message.usage.promptTokens) }}
              </span>
            </div>
          </template>
        </div>
      </div>

      <AgentTaskCard
        v-if="agent.activeTask"
        :task="agent.activeTask"
        @close="agent.dismissTask()"
      />

      <footer class="agent-foot">
        <div class="ctx-row" :class="ctxTone">
          <span class="ctx-label">上下文</span>
          <span class="ctx-track" :title="ctxSummary">
            <span class="ctx-fill" :style="{ width: ctxBarWidth + '%' }"></span>
          </span>
          <span class="ctx-text" :title="ctxSummary">
            <template v-if="ctxWindow > 0">{{ ctxPercentText }}%</template>
            <template v-else>待统计</template>
          </span>
          <span
            class="ctx-cache"
            :class="{ good: cacheRate !== null && cacheRate >= 60 }"
            :title="cacheTooltip"
          >
            {{ cacheText }}
          </span>
          <button
            v-if="agent.currentSessionId"
            type="button"
            class="ctx-compact"
            :disabled="agent.streaming || agent.compacting"
            title="把更早的历史压缩成摘要，释放上下文"
            @click="compactHistory"
          >
            {{ agent.compacting ? '压缩中…' : '压缩历史' }}
          </button>
        </div>
        <div v-if="agent.context.compacted" class="ctx-note">
          <span>
            已压缩 {{ agent.context.compacted.count }} 条历史，释放约
            {{ formatTokens(agent.context.compacted.freedTokens) }} tokens
          </span>
          <button type="button" class="ctx-note-close" @click="agent.context.compacted = null">×</button>
        </div>
        <textarea
          v-model="input"
          class="agent-input"
          rows="2"
          placeholder="问问数据、找素材，或让它生成大纲…（Enter 发送，Shift+Enter 换行）"
          @keydown="onKeydown"
        />
        <div class="agent-foot-row">
          <span class="agent-hint">生成结果会自动保存 · 查询类工具只读</span>
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

    <el-dialog v-model="settingsOpen" title="Agent 设置" width="min(480px, 92vw)" :teleported="false">
      <el-form label-width="108px" size="small" class="settings-form">
        <el-form-item>
          <template #label>
            <SettingLabel text="访问 DeepSeek 的密钥。留空表示不修改；读取时只显示脱敏值。">API Key</SettingLabel>
          </template>
          <el-input
            v-model="form.apiKey"
            show-password
            :placeholder="hasApiKey ? '已配置，留空则不修改' : 'sk-...'"
          />
          <div v-if="hasApiKey" class="form-hint mono">当前：{{ maskedKey }}</div>
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="接口地址，默认 https://api.deepseek.com；使用代理或兼容服务时修改。">
              Base URL
            </SettingLabel>
          </template>
          <el-input v-model="form.baseUrl" :placeholder="defaultBaseUrl" />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="对话模型。Flash 响应快，Pro 推理强、适合复杂任务与长文创作；也可以自己输入模型名。">
              模型
            </SettingLabel>
          </template>
          <el-select
            v-model="form.model"
            filterable
            allow-create
            default-first-option
            :placeholder="defaultModel"
            class="model-select"
          >
            <el-option
              v-for="option in modelOptions"
              :key="option.id"
              :label="option.label"
              :value="option.id"
            >
              <div class="model-option">
                <span class="model-option-label">{{ option.label }}</span>
                <span class="model-option-desc">{{ option.description }}</span>
              </div>
            </el-option>
          </el-select>
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="0~2，越大越发散。默认 1，创作类任务建议 0.8~1.2。">
              Temperature
            </SettingLabel>
          </template>
          <el-input-number v-model="form.temperature" :min="0" :max="2" :step="0.1" controls-position="right" />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="单次回复的最大 token 数，默认 32768（当前允许的最大值）。">
              Max Tokens
            </SettingLabel>
          </template>
          <el-input-number
            v-model="form.maxTokens"
            :min="256"
            :max="32768"
            :step="512"
            controls-position="right"
          />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="核采样阈值 0~1，和 Temperature 二选一调整即可。">Top P</SettingLabel>
          </template>
          <el-input-number v-model="form.topP" :min="0" :max="1" :step="0.05" controls-position="right" />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="-2~2，正值降低重复用词。默认 0。">频率惩罚</SettingLabel>
          </template>
          <el-input-number
            v-model="form.frequencyPenalty"
            :min="-2"
            :max="2"
            :step="0.1"
            controls-position="right"
          />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="-2~2，正值鼓励引入新话题。默认 0。">存在惩罚</SettingLabel>
          </template>
          <el-input-number
            v-model="form.presencePenalty"
            :min="-2"
            :max="2"
            :step="0.1"
            controls-position="right"
          />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="上下文窗口（tokens）。DeepSeek Flash / Pro 都是 1M；填 0 表示按模型默认，自建小窗口模型时按实际填写。">
              上下文窗口
            </SettingLabel>
          </template>
          <el-input-number
            v-model="form.contextWindow"
            :min="0"
            :max="2000000"
            :step="10000"
            controls-position="right"
          />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="追加到系统提示词后面，用来约束语气、格式或角色。">追加提示词</SettingLabel>
          </template>
          <el-input
            v-model="form.systemPrompt"
            type="textarea"
            :rows="3"
            placeholder="例如：回答尽量简短"
          />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="逐字显示回复。关闭后整段返回，适合网络不稳定时。默认开启。">
              流式输出
            </SettingLabel>
          </template>
          <el-switch v-model="form.stream" />
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="开启后模型会先思考再回答，过程会实时显示在对话里；耗时与 token 消耗更高，关闭则直接输出。">
              思考模式
            </SettingLabel>
          </template>
          <el-switch v-model="form.thinking" />
        </el-form-item>
        <el-form-item v-if="form.thinking">
          <template #label>
            <SettingLabel text="思考深度：none 不思考、low 浅、high 标准、max 最深。越深越慢，但复杂任务更稳。">
              思考深度
            </SettingLabel>
          </template>
          <el-select v-model="form.reasoningEffort" class="model-select">
            <el-option
              v-for="effort in reasoningEfforts"
              :key="effort"
              :label="effortLabel(effort)"
              :value="effort"
            />
          </el-select>
        </el-form-item>
        <el-form-item>
          <template #label>
            <SettingLabel text="开启后 Agent 才能调用 web_search；搜索按次计费。">联网搜索</SettingLabel>
          </template>
          <el-switch v-model="form.webSearch" />
        </el-form-item>
        <template v-if="form.webSearch">
          <el-form-item>
            <template #label>
              <SettingLabel text="每次搜索返回的条数。默认 5，实际最多取 8 条。">搜索条数</SettingLabel>
            </template>
            <el-input-number
              v-model="form.searchCount"
              :min="1"
              :max="20"
              :step="1"
              controls-position="right"
            />
          </el-form-item>
          <el-form-item>
            <template #label>
              <SettingLabel text="开启后返回网页正文，信息更全但更耗上下文。">抓取正文</SettingLabel>
            </template>
            <el-switch v-model="form.searchNeedContent" />
          </el-form-item>
        </template>
      </el-form>
      <template #footer>
        <el-button @click="settingsOpen = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="saveSettings">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="downloadsOpen" title="下载库" width="min(540px, 92vw)" :teleported="false">
      <AgentDownloadList
        :items="downloadItems"
        :loading="downloadsLoading"
        @refresh="refreshDownloads"
        @delete="removeDownload"
      />
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
  background: var(--warn);
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

/* ── 错误条 ── */
.agent-error {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  flex: 0 0 auto;
  margin: 8px 12px 0;
  padding: 7px 9px;
  border-radius: 7px;
  background: var(--danger-soft);
  color: var(--danger);
  font-size: 11.5px;
  line-height: 1.55;
}

.agent-error-text {
  flex: 1;
  min-width: 0;
  word-break: break-word;
}

/* ── 消息区 ── */
.agent-body {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 18px;
}

/* 轮与轮之间（上一条助手回答结束 → 下一条用户提问）再额外留一段，
   避免连续几轮对话像一整段文字一样粘在一起 */
.msg + .msg.user {
  margin-top: 12px;
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

/* 单条回答的缓存命中（会话累计在底部 ctx-cache 里） */
.msg-cache {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-top: 3px;
  font-size: 10.5px;
  color: var(--ink-4);
  cursor: default;
}

.msg-cache-dot {
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: currentColor;
  opacity: 0.7;
}

.msg-cache.good {
  color: var(--brand);
}

.msg-cache-tokens {
  color: var(--ink-4);
  opacity: 0.85;
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

/* ── 上下文占用 ── */
.ctx-row {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-bottom: 6px;
  font-size: 10.5px;
  color: var(--ink-4);
}

.ctx-label {
  flex: 0 0 auto;
}

.ctx-track {
  position: relative;
  flex: 1 1 auto;
  height: 4px;
  min-width: 40px;
  border-radius: 999px;
  background: var(--bg-soft);
  overflow: hidden;
}

.ctx-fill {
  display: block;
  height: 100%;
  width: 0;
  border-radius: 999px;
  background: var(--brand);
  transition: width 0.25s ease;
}

.ctx-row.warn .ctx-fill {
  background: var(--warn);
}

.ctx-row.danger .ctx-fill {
  background: var(--danger);
}

.ctx-text {
  flex: 0 0 auto;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.ctx-cache {
  flex: 0 0 auto;
  padding: 1px 5px;
  border-radius: 5px;
  background: var(--bg-soft);
  color: var(--ink-4);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.ctx-cache.good {
  color: var(--brand);
}

.ctx-compact {
  flex: 0 0 auto;
  padding: 1px 6px;
  border: 1px solid var(--line);
  border-radius: 5px;
  background: transparent;
  color: var(--ink-3);
  font-size: 10px;
  cursor: pointer;
}

.ctx-compact:hover:not(:disabled) {
  color: var(--ink-1);
  border-color: var(--ink-4);
}

.ctx-compact:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.ctx-note {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 6px;
  padding: 4px 8px;
  border-radius: 6px;
  background: var(--bg-soft);
  color: var(--ink-3);
  font-size: 10.5px;
}

.ctx-note-close {
  border: none;
  background: transparent;
  color: var(--ink-4);
  cursor: pointer;
  font-size: 13px;
  line-height: 1;
}

/* ── 设置弹窗 ── */
.settings-form {
  padding-right: 6px;
  max-height: 60vh;
  overflow-y: auto;
}

.model-select {
  width: 100%;
}

.model-option {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.model-option-label {
  font-size: 12px;
  color: var(--ink-1);
}

.model-option-desc {
  font-size: 10.5px;
  color: var(--ink-4);
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
