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
.meta-row {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 12px;
  margin-bottom: 16px;
}

.meta-chip {
  background: #fff;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  padding: 12px 16px;
  box-shadow: var(--shadow-1);
}

.meta-label { display: block; font-size: 12px; color: var(--ink-3); }
.meta-value { display: block; margin-top: 4px; font-size: 19px; font-weight: 650; letter-spacing: -0.4px; }

.summary-card {
  display: flex;
  gap: 12px;
  background: linear-gradient(135deg, #f3f6ff, #eef1ff);
  border: 1px solid #e0e7ff;
  border-radius: var(--r-lg);
  padding: 16px 18px;
  margin-bottom: 20px;
}

.summary-icon {
  width: 30px;
  height: 30px;
  flex: 0 0 30px;
  border-radius: 9px;
  display: grid;
  place-items: center;
  background: #fff;
  color: var(--brand);
}

.summary-label { font-size: 12px; font-weight: 600; color: var(--brand); letter-spacing: 0.3px; }
.summary-text { margin-top: 5px; font-size: 13.5px; line-height: 1.75; color: var(--ink-2); }

.thread { display: flex; flex-direction: column; gap: 20px; }

.turn { display: flex; gap: 12px; }
.turn.is-user { flex-direction: row-reverse; }

.avatar {
  width: 34px;
  height: 34px;
  flex: 0 0 34px;
  border-radius: 11px;
  display: grid;
  place-items: center;
  font-size: 15px;
  color: #fff;
  margin-top: 22px;
}

.av-ai { background: linear-gradient(135deg, #5b78ff, #3b57e8); box-shadow: 0 6px 16px -8px rgba(77, 107, 254, 0.9); }
.av-user { background: linear-gradient(135deg, #94a3b8, #64748b); }

.bubble-wrap { min-width: 0; max-width: 80%; }
.turn.is-user .bubble-wrap { display: flex; flex-direction: column; align-items: flex-end; }

.bubble-head {
  display: flex;
  align-items: center;
  gap: 9px;
  margin-bottom: 6px;
  font-size: 11.5px;
  color: var(--ink-3);
}

.turn.is-user .bubble-head { flex-direction: row-reverse; }
.who { font-weight: 600; color: var(--ink-2); font-size: 12.5px; }
.mid { color: var(--ink-4); }

.bubble {
  background: #fff;
  border: 1px solid var(--line);
  border-radius: 4px 14px 14px 14px;
  padding: 14px 16px;
  box-shadow: var(--shadow-1);
}

.turn.is-user .bubble {
  background: linear-gradient(135deg, #eef1ff, #e4e9ff);
  border-color: #dbe2ff;
  border-radius: 14px 4px 14px 14px;
}

.bubble-text { line-height: 1.8; font-size: 13.8px; color: var(--ink-1); }

.think { margin-top: 10px; }
.think-title { display: inline-flex; align-items: center; gap: 5px; font-size: 12.5px; color: var(--ink-3); }

.think-body {
  font-size: 12.8px;
  line-height: 1.75;
  color: var(--ink-2);
  background: var(--bg-soft);
  border-left: 2px solid var(--line-strong);
  border-radius: 0 8px 8px 0;
  padding: 10px 12px;
}

.sources { margin-top: 12px; padding-top: 12px; border-top: 1px dashed var(--line-strong); }
.sources-title { display: flex; align-items: center; gap: 5px; font-size: 12px; color: var(--ink-3); margin-bottom: 7px; }

.source {
  display: block;
  padding: 7px 10px;
  border-radius: 8px;
  text-decoration: none;
  margin-bottom: 5px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  transition: background 0.15s ease;
}
.source:hover { background: var(--brand-soft); border-color: #dbe2ff; }
.source-title { display: block; font-size: 12.5px; color: var(--brand); font-weight: 500; }
.source-url { display: block; font-size: 11px; color: var(--ink-4); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
