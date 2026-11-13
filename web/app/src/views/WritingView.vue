<script setup lang="ts">
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import {
  Aim, DocumentCopy, Download, EditPen, Headset, MagicStick, Promotion, Reading, Upload, VideoPlay,
} from '@element-plus/icons-vue';
import PageHeader from '@/components/PageHeader.vue';
import OutlineTxtExportDialog from './writing/OutlineTxtExportDialog.vue';
import OutlineTxtImportDialog from './writing/OutlineTxtImportDialog.vue';

const router = useRouter();

const exportVisible = ref(false);
const importVisible = ref(false);

const features = [
  {
    path: '/writing/outline/generate',
    title: '一键生成大纲',
    subtitle: '填写题材与设定，AI 流式生成整部作品的大纲和小事件',
    icon: MagicStick,
  },
  {
    path: '/writing/outlines?intent=edit',
    title: '大纲编辑',
    subtitle: '选择作品，逐个事件精修大纲，支持 AI 按指令改写',
    icon: EditPen,
  },
  {
    path: '/writing/outlines?intent=convert',
    title: '小事件详写',
    subtitle: '按大纲拆出小事件结构，逐个生成正文',
    icon: DocumentCopy,
  },
  {
    path: '/writing/outlines?intent=chapters',
    title: '小事件写作',
    subtitle: '选择小事件写正文，AI 生成本篇并保存回库',
    icon: Reading,
  },
  {
    path: '/writing/listen',
    title: '听大纲改名',
    subtitle: '边听边改，一键替换人名地名',
    icon: Headset,
  },
  {
    path: '/writing/battle',
    title: 'AI 写战斗',
    subtitle: '填写战斗要素，生成完整的战斗场面',
    icon: Aim,
  },
  {
    path: '/writing/format',
    title: '匹配大纲格式',
    subtitle: '解析外部大纲文本为可用格式',
    icon: Reading,
  },
  {
    path: '/writing/tools',
    title: '写作工具',
    subtitle: '自由优化、短篇抽卡、大纲骨架抽卡',
    icon: Promotion,
  },
  {
    path: '/writing/bili',
    title: 'B站视频转文字',
    subtitle: '粘贴B站链接，提取官方字幕或本地转写成文字稿',
    icon: VideoPlay,
  },
];

/** 导出 / 导入大纲 txt：不跳转路由，分别打开对应弹窗（接在功能列表末尾） */
const fileFeatures = [
  {
    key: 'export',
    title: '导出大纲 txt',
    subtitle: '选一部作品，把大纲正文原样存成 .txt 文件',
    icon: Download,
  },
  {
    key: 'import',
    title: '导入大纲 txt',
    subtitle: '选 .txt 文件新建作品大纲，不经过 AI',
    icon: Upload,
  },
];

function openFileFeature(key: string) {
  if (key === 'export') {
    exportVisible.value = true;
  } else if (key === 'import') {
    importVisible.value = true;
  }
}
</script>

<template>
  <div class="page">
    <PageHeader
      title="写作"
      desc="选择要用的功能。作品与事件来自当前设备的数据库，电脑上的修改会同步回手机。"
    />

    <div class="feature-card card">
      <button
        v-for="item in features"
        :key="item.path"
        type="button"
        class="feature-row"
        @click="router.push(item.path)"
      >
        <span class="feature-icon"><el-icon><component :is="item.icon" /></el-icon></span>
        <span class="feature-main">
          <span class="feature-title">{{ item.title }}</span>
          <span class="feature-sub">{{ item.subtitle }}</span>
        </span>
        <span class="feature-arrow">›</span>
      </button>

      <!-- 导出 / 导入大纲 txt：直接接在功能列表末尾，不单起分区标题 -->
      <button
        v-for="item in fileFeatures"
        :key="item.key"
        type="button"
        class="feature-row"
        @click="openFileFeature(item.key)"
      >
        <span class="feature-icon"><el-icon><component :is="item.icon" /></el-icon></span>
        <span class="feature-main">
          <span class="feature-title">{{ item.title }}</span>
          <span class="feature-sub">{{ item.subtitle }}</span>
        </span>
        <span class="feature-arrow">›</span>
      </button>
    </div>

    <OutlineTxtExportDialog v-model="exportVisible" />
    <OutlineTxtImportDialog v-model="importVisible" />
  </div>
</template>

<style scoped>
.feature-card {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
  padding: 0;
  background: transparent;
  border: none;
  box-shadow: none;
}

@media (max-width: 880px) {
  .feature-card { grid-template-columns: minmax(0, 1fr); }
}

.feature-row {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 9px;
  min-height: 118px;
  padding: 19px 20px 18px;
  border: 1px solid var(--line);
  border-radius: var(--r-lg);
  background: var(--bg-card);
  text-align: left;
  cursor: pointer;
  transition: border-color 0.18s ease, background 0.18s ease, transform 0.18s ease;
}

.feature-row:hover {
  border-color: var(--ink-4);
  background: #fbf9f4;
  transform: translateY(-1px);
}

.feature-icon {
  width: 30px;
  height: 30px;
  flex: 0 0 30px;
  display: grid;
  place-items: center;
  border-radius: 7px;
  border: 1px solid var(--line);
  background: transparent;
  color: var(--ink-2);
  font-size: 15px;
}

.feature-main { display: flex; flex-direction: column; gap: 4px; padding-right: 28px; }

.feature-title {
  font-size: 13.5px;
  font-weight: 550;
  letter-spacing: 0.1px;
  color: var(--ink-1);
}

.feature-sub {
  font-size: 11.5px;
  color: var(--ink-3);
  line-height: 1.6;
}

.feature-arrow {
  position: absolute;
  right: 19px;
  bottom: 18px;
  color: var(--ink-4);
  font-size: 15px;
  line-height: 1;
  transition: transform 0.18s ease, color 0.18s ease;
}

.feature-row:hover .feature-arrow {
  color: var(--ink-1);
  transform: translateX(2px);
}
</style>