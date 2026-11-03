<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { Refresh } from '@element-plus/icons-vue';
import type { Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import { isMajor, loadChapters, loadOutline, statsOf } from './novelApi';

const props = defineProps<{ id: string }>();
const router = useRouter();

const outline = ref<Row | null>(null);
const chapters = ref<Row[]>([]);
const loading = ref(false);

const outlineId = computed(() => Number(props.id));
const stats = computed(() => statsOf(chapters.value));
const minorRows = computed(() => chapters.value.filter((row) => !isMajor(row)));

async function load() {
  loading.value = true;
  try {
    outline.value = await loadOutline(outlineId.value);
    chapters.value = await loadChapters(outlineId.value);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

onMounted(load);
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader
      :title="String(outline?.title || '小事件选择')"
      :desc="`共 ${stats.minor} 个小事件，已写 ${stats.written} 个。选一个小事件进入写作页。`"
      back="/writing/outlines?intent=chapters"
    >
      <template #actions>
        <el-button :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <div v-if="!minorRows.length" class="card empty-hint">
      这部作品还没有可写的小事件，先去「小事件详写」拆出小事件结构。
    </div>

    <div v-else class="chapter-list">
      <template v-for="item in chapters" :key="String(item.id)">
        <div v-if="isMajor(item)" class="major-row">
          <span class="major-title">{{ item.event_title || '未命名大事件' }}</span>
          <span class="major-tag">大事件</span>
        </div>
        <button v-else type="button" class="chapter-row card" @click="router.push('/writing/chapter/' + item.id)">
          <span class="cr-index">{{ item.event_index }}</span>
          <span class="cr-main">
            <span class="cr-title">{{ item.event_title || '未命名小事件' }}</span>
            <span class="cr-meta">
              {{ String(item.status) === 'completed' ? '已写' : '待写' }}
              <template v-if="String(item.content ?? '').trim()"> · {{ String(item.content).length }} 字</template>
            </span>
          </span>
          <span class="cr-arrow">›</span>
        </button>
      </template>
    </div>
  </div>
</template>

<style scoped>
.chapter-list { display: flex; flex-direction: column; gap: 10px; }

.major-row { display: flex; align-items: center; gap: 8px; padding: 10px 4px 2px; }
.major-title { font-size: 12px; font-weight: 600; color: var(--ink-3); }
.major-tag {
  padding: 1px 6px;
  border-radius: 5px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  color: var(--ink-4);
  font-size: 10px;
}

.chapter-row {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  padding: 15px 18px;
  margin-bottom: 0;
  text-align: left;
  cursor: pointer;
  border: none;
  transition: box-shadow 0.15s ease, transform 0.15s ease;
}

.chapter-row:hover { box-shadow: var(--shadow-pop); }

.cr-index {
  width: 26px;
  height: 26px;
  flex: 0 0 26px;
  display: grid;
  place-items: center;
  border-radius: 7px;
  background: var(--bg-soft);
  color: var(--ink-3);
  font-size: 11px;
  font-variant-numeric: tabular-nums;
}

.cr-main { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 0; }

.cr-title {
  font-size: 14px;
  font-weight: 500;
  color: var(--ink-1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.cr-meta { font-size: 11.5px; color: var(--ink-4); }
.cr-arrow { color: var(--ink-4); font-size: 20px; }
</style>
