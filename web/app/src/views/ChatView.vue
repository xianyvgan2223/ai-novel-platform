<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { ArrowLeft, Cpu, Link as LinkIcon, Refresh, User } from '@element-plus/icons-vue';
import { api, formatTime } from '@/api';
import type { Row } from '@/api';
import { deviceEpoch } from '@/stores/device';
import PageHeader from '@/components/PageHeader.vue';
import RichText from '@/components/RichText.vue';

const props = defineProps<{ id: string }>();
const router = useRouter();

const session = ref<Row | null>(null);
const messages = ref<Row[]>([]);
const loading = ref(false);

const sessionId = computed(() => Number(props.id));
const userCount = computed(() => messages.value.filter((m) => m.role === 'user').length);
const totalChars = computed(() =>
  messages.value.reduce((sum, m) => sum + String(m.content ?? '').length, 0),
);

async function load() {
  loading.value = true;
  try {
    session.value = await api.getRow('deepseek', 'chat_sessions', sessionId.value);
    const res = await api.listRows('deepseek', 'chat_messages', {
      session_id: sessionId.value,
      page: 1,
      pageSize: 500,
      full: 1,
      orderBy: 'id',
      dir: 'asc',
    });
    messages.value = res.data;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

function parseSearchResults(raw: unknown): { title?: string; url?: string }[] {
  if (!raw || typeof raw !== 'string') return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

// 切换设备后可能根本不存在这个会话（各设备主键独立），重新取一次
watch(deviceEpoch, () => void load());
onMounted(load);
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader :title="String(session?.title ?? '会话 #' + id)" :desc="'共 ' + messages.length + ' 条消息 · 创建于 ' + formatTime(session?.create_time)">
      <template #actions>
        <el-button :icon="ArrowLeft" @click="router.push('/sessions')">返回列表</el-button>
        <el-button :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <div class="meta-row">
      <div class="meta-chip">
        <span class="meta-label">消息总数</span>
        <span class="meta-value tnum">{{ messages.length }}</span>
      </div>
      <div class="meta-chip">
        <span class="meta-label">用户提问</span>
        <span class="meta-value tnum">{{ userCount }}</span>
      </div>
      <div class="meta-chip">
        <span class="meta-label">正文字数</span>
        <span class="meta-value tnum">{{ totalChars }}</span>
      </div>
      <div class="meta-chip">
        <span class="meta-label">会话 ID</span>
        <span class="meta-value mono">{{ id }}</span>
      </div>
    </div>

    <div v-if="session?.summary" class="summary-card">
      <div class="summary-icon"><Cpu /></div>
      <div>
        <div class="summary-label">会话摘要</div>
        <div class="summary-text">{{ session.summary }}</div>
      </div>
    </div>

    <div class="thread">
      <div
        v-for="msg in messages"
        :key="String(msg.id)"
        class="turn"
        :class="msg.role === 'user' ? 'is-user' : 'is-ai'"
      >
        <div class="avatar" :class="msg.role === 'user' ? 'av-user' : 'av-ai'">
          <el-icon><component :is="msg.role === 'user' ? User : Cpu" /></el-icon>
        </div>
        <div class="bubble-wrap">
          <div class="bubble-head">
            <span class="who">{{ msg.role === 'user' ? '我' : 'DeepSeek' }}</span>
            <span class="when mono">{{ formatTime(msg.timestamp) }}</span>
            <span class="mid mono">#{{ msg.id }}</span>
          </div>

          <div class="bubble">
            <RichText class="bubble-text" :text="String(msg.content ?? '')" />

            <el-collapse v-if="msg.thinking_text" class="think">
              <el-collapse-item>
                <template #title>
                  <span class="think-title"><el-icon><Cpu /></el-icon> 思考过程</span>
                </template>
                <RichText class="think-body" :text="String(msg.thinking_text ?? '')" />
              </el-collapse-item>
            </el-collapse>

            <div v-if="parseSearchResults(msg.search_results).length" class="sources">
              <div class="sources-title"><el-icon><LinkIcon /></el-icon> 联网搜索来源</div>
              <a
                v-for="(item, index) in parseSearchResults(msg.search_results)"
                :key="index"
                class="source"
                :href="item.url"
                target="_blank"
                rel="noreferrer"
              >
                <span class="source-title">{{ item.title || item.url }}</span>
                <span class="source-url">{{ item.url }}</span>
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div v-if="!loading && !messages.length" class="card">
      <div class="empty-hint">该会话暂无消息</div>
    </div>
  </div>
</template>

<style scoped>
.page { max-width: 1120px; }

.meta-row {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 10px;
  margin-bottom: 22px;
}

.meta-chip {
  background: transparent;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  padding: 13px 16px;
}

.meta-label {
  display: block;
  font-size: 11.5px;
  letter-spacing: 0.3px;
  color: var(--ink-3);
}
.meta-value {
  display: block;
  margin-top: 5px;
  font-size: 20px;
  font-weight: 520;
  letter-spacing: -0.4px;
  color: var(--ink-1);
}

.summary-card {
  display: flex;
  gap: 14px;
  background: transparent;
  border: none;
  border-left: 2px solid var(--ink-1);
  border-radius: 0;
  padding: 2px 0 2px 16px;
  margin: 4px 0 30px;
}

.summary-icon {
  width: 22px;
  height: 22px;
  flex: 0 0 22px;
  display: grid;
  place-items: center;
  color: var(--ink-3);
  font-size: 14px;
}

.summary-label {
  font-size: 11px;
  font-weight: 600;
  color: var(--ink-3);
  letter-spacing: 0.5px;
}
.summary-text { margin-top: 6px; font-size: 13px; line-height: 1.85; color: var(--ink-2); }

.thread { display: flex; flex-direction: column; gap: 26px; }

.turn { display: flex; gap: 13px; }
.turn.is-user { flex-direction: row-reverse; }

.avatar {
  width: 28px;
  height: 28px;
  flex: 0 0 28px;
  border-radius: 50%;
  display: grid;
  place-items: center;
  font-size: 13px;
  margin-top: 22px;
  border: 1px solid var(--line-strong);
  background: var(--bg-card);
  color: var(--ink-2);
}

.av-ai { color: var(--ink-1); }
.av-user { background: var(--bubble-user-bg); border-color: var(--bubble-user-bg); color: var(--bubble-user-text); }

.bubble-wrap { min-width: 0; max-width: 78%; }
.turn.is-user .bubble-wrap { display: flex; flex-direction: column; align-items: flex-end; }

.bubble-head {
  display: flex;
  align-items: center;
  gap: 9px;
  margin-bottom: 7px;
  font-size: 11px;
  color: var(--ink-3);
  letter-spacing: 0.2px;
}

.turn.is-user .bubble-head { flex-direction: row-reverse; }
.who { font-weight: 600; color: var(--ink-2); font-size: 12.5px; }
.mid { color: var(--ink-4); }

.bubble {
  background: transparent;
  border: none;
  border-radius: 0;
  padding: 0 2px;
  box-shadow: none;
}

.turn.is-user .bubble {
  background: var(--bubble-user-bg);
  border: 1px solid var(--bubble-user-bg);
  border-radius: 12px 3px 12px 12px;
  padding: 12px 15px;
}

.bubble-text { line-height: 1.85; font-size: 13.5px; color: var(--ink-1); }
.turn.is-user .bubble-text { color: var(--bubble-user-text); }
.turn.is-user :deep(.rt strong),
.turn.is-user :deep(.rt .rt-h) { color: var(--bubble-user-text); }

.think { margin-top: 12px; }
.think-title { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; color: var(--ink-3); }

.think-body {
  font-size: 12px;
  line-height: 1.8;
  color: var(--ink-2);
  background: var(--bg-soft);
  border-left: 1px solid var(--line-strong);
  border-radius: 0 6px 6px 0;
  padding: 10px 12px;
}

.sources { margin-top: 14px; padding-top: 12px; border-top: 1px solid var(--line); }
.sources-title { display: flex; align-items: center; gap: 5px; font-size: 11.5px; color: var(--ink-3); margin-bottom: 8px; }

.source {
  display: block;
  padding: 8px 10px;
  border-radius: 7px;
  text-decoration: none;
  margin-bottom: 6px;
  background: transparent;
  border: 1px solid var(--line);
  transition: border-color 0.15s ease, background 0.15s ease;
}
.source:hover { background: var(--bg-soft); border-color: var(--ink-4); }
.source-title { display: block; font-size: 12.5px; color: var(--ink-1); font-weight: 500; }
.source-url { display: block; font-size: 11px; color: var(--ink-3); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>