<script setup lang="ts">
import { onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage, ElMessageBox } from 'element-plus';
import { Delete, Refresh, Search, View } from '@element-plus/icons-vue';
import { api, formatTime } from '@/api';
import type { Row } from '@/api';
import { useServerStore } from '@/stores/server';
import { deviceEpoch } from '@/stores/device';
import PageHeader from '@/components/PageHeader.vue';

const router = useRouter();
const store = useServerStore();

const rows = ref<Row[]>([]);
const loading = ref(false);
const keyword = ref('');
const page = ref(1);
const pageSize = ref(20);
const total = ref(0);

const AVATAR_TONES = ['brand', 'violet', 'emerald', 'amber', 'cyan', 'rose'];

/** 用标题做一个稳定的配色，让列表看起来是有设计的 */
function avatarTone(title: unknown) {
  const text = String(title ?? '');
  let hash = 0;
  for (let i = 0; i < text.length; i += 1) hash = (hash * 31 + text.charCodeAt(i)) % 997;
  return AVATAR_TONES[hash % AVATAR_TONES.length];
}

async function load() {
  loading.value = true;
  try {
    const res = await api.listRows('deepseek', 'chat_sessions', {
      page: page.value,
      pageSize: pageSize.value,
      q: keyword.value || undefined,
      orderBy: 'create_time',
      dir: 'desc',
    });
    rows.value = res.data;
    total.value = res.meta.total;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

function search() {
  page.value = 1;
  void load();
}

function openChat(row: Row) {
  void router.push('/sessions/' + row.id);
}

async function remove(row: Row) {
  try {
    await ElMessageBox.confirm(
      '将同时删除该会话下的全部消息（级联删除），并写入同步日志。确定删除？',
      '删除会话「' + String(row.title) + '」',
      { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' },
    );
  } catch {
    return;
  }
  try {
    const result = await api.deleteRow('deepseek', 'chat_sessions', Number(row.id));
    ElMessage.success('已删除，共影响 ' + result.count + ' 行');
    await Promise.all([load(), store.refreshStats()]);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

watch([page, pageSize], () => void load());
// 切换设备（数据隔离）后，列表要换成那台设备的会话
watch(deviceEpoch, () => {
  page.value = 1;
  void load();
});
onMounted(load);
</script>

<template>
  <div class="page">
    <PageHeader title="对话会话" desc="来自 App 的 chat_sessions 表，双击一行查看完整消息记录。">
      <template #actions>
        <el-input
          v-model="keyword"
          placeholder="搜索标题 / 末条消息 / 摘要"
          clearable
          style="width: 260px"
          @keyup.enter="search"
          @clear="search"
        >
          <template #prefix><el-icon><Search /></el-icon></template>
        </el-input>
        <el-button :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <div class="card card-flush">
      <el-table v-loading="loading" :data="rows" style="cursor: pointer" @row-dblclick="openChat">
        <el-table-column label="会话" min-width="380">
          <template #default="{ row }">
            <div class="sess">
              <div class="sess-avatar" :class="'tone-' + avatarTone(row.title)">
                {{ String(row.title ?? '?').slice(0, 1) }}
              </div>
              <div class="sess-main">
                <div class="sess-title">{{ row.title || '(无标题)' }}</div>
                <div class="sess-sub">{{ row.summary || row.last_message || '暂无内容' }}</div>
              </div>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="最后一条消息" min-width="260">
          <template #default="{ row }">
            <span class="cell-clamp">{{ row.last_message || '—' }}</span>
          </template>
        </el-table-column>
        <el-table-column label="创建时间" width="170">
          <template #default="{ row }">
            <span class="text-muted">{{ formatTime(row.create_time) }}</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="176" align="right">
          <template #default="{ row }">
            <el-button link type="primary" :icon="View" @click.stop="openChat(row)">查看</el-button>
            <el-button link type="danger" :icon="Delete" @click.stop="remove(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>

      <div class="card-foot">
        <span class="text-muted" style="font-size: 12.5px">
          共 <b class="tnum">{{ total }}</b> 条会话
        </span>
        <el-pagination
          v-model:current-page="page"
          v-model:page-size="pageSize"
          :total="total"
          :page-sizes="[20, 50, 100]"
          layout="sizes, prev, pager, next, jumper"
          background
        />
      </div>
    </div>
  </div>
</template>

<style scoped>
.sess { display: flex; align-items: center; gap: 13px; padding: 4px 0; }

.sess-avatar {
  width: 34px;
  height: 34px;
  flex: 0 0 34px;
  border-radius: 8px;
  display: grid;
  place-items: center;
  font-family: var(--font-serif);
  font-size: 15px;
  font-weight: 500;
  color: var(--ink-2);
  background: var(--bg-soft);
  border: 1px solid var(--line);
}

.sess-main { min-width: 0; }
.sess-title { font-weight: 550; color: var(--ink-1); font-size: 14px; letter-spacing: 0.1px; }
.sess-sub {
  margin-top: 3px;
  font-size: 12.5px;
  color: var(--ink-3);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* 兼容旧模板里的 tone class：统一成中性纸色 */
.tone-brand, .tone-violet, .tone-emerald, .tone-amber, .tone-cyan, .tone-rose {
  --tone-color: var(--ink-2);
  --tone-soft: var(--bg-soft);
}
</style>