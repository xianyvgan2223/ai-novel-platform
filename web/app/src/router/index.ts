import { createRouter, createWebHistory } from 'vue-router';

/**
 * 路由采用 history 模式：服务端已配置 SPA 回退，
 * 直接访问 /sessions/3 也能正常打开。
 */
export const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/',
      name: 'overview',
      component: () => import('@/views/OverviewView.vue'),
      meta: { title: '总览' },
    },
    {
      path: '/sessions',
      name: 'sessions',
      component: () => import('@/views/SessionsView.vue'),
      meta: { title: '对话会话' },
    },
    {
      path: '/writing',
      name: 'writing',
      component: () => import('@/views/WritingView.vue'),
      meta: { title: '写作' },
    },
    {
      path: '/writing/outline/generate',
      name: 'writing-outline-generate',
      component: () => import('@/views/writing/OutlineGenerateView.vue'),
      meta: { title: '一键生成大纲' },
    },
    {
      path: '/writing/outlines',
      name: 'writing-outlines',
      component: () => import('@/views/writing/OutlineSelectView.vue'),
      meta: { title: '大纲 / 作品' },
    },
    {
      path: '/writing/outline/:id/edit',
      name: 'writing-outline-edit',
      component: () => import('@/views/writing/OutlineEditView.vue'),
      props: true,
      meta: { title: '大纲编辑' },
    },
    {
      path: '/writing/outline/:id/convert',
      name: 'writing-outline-convert',
      component: () => import('@/views/writing/OutlineConvertView.vue'),
      props: true,
      meta: { title: '小事件详写' },
    },
    {
      path: '/writing/outline/:id/chapters',
      name: 'writing-chapter-select',
      component: () => import('@/views/writing/ChapterSelectView.vue'),
      props: true,
      meta: { title: '小事件选择' },
    },
    {
      path: '/writing/chapter/:id',
      name: 'writing-chapter',
      component: () => import('@/views/writing/ChapterWriteView.vue'),
      props: true,
      meta: { title: '小事件写作' },
    },
    {
      path: '/writing/listen',
      name: 'writing-listen',
      component: () => import('@/views/writing/OutlineListenView.vue'),
      meta: { title: '听大纲改名' },
    },
    {
      path: '/writing/battle',
      name: 'writing-battle',
      component: () => import('@/views/writing/AiBattleView.vue'),
      meta: { title: 'AI 写战斗' },
    },
    {
      path: '/writing/format',
      name: 'writing-format',
      component: () => import('@/views/writing/OutlineFormatView.vue'),
      meta: { title: '匹配大纲格式' },
    },
    {
      path: '/writing/tools',
      name: 'writing-tools',
      component: () => import('@/views/writing/WritingToolsView.vue'),
      meta: { title: '写作工具' },
    },
    {
      path: '/bili',
      name: 'bili-transcript',
      component: () => import('@/views/BiliTranscriptView.vue'),
      meta: { title: 'B站视频转文字' },
    },
    {
      path: '/rag',
      name: 'rag',
      component: () => import('@/views/RagView.vue'),
      meta: { title: '情节素材库' },
    },
    {
      path: '/writing/bili',
      redirect: '/bili',
    },
    {
      path: '/sessions/:id',
      name: 'chat',
      component: () => import('@/views/ChatView.vue'),
      props: true,
      meta: { title: '会话详情' },
    },
    {
      path: '/browse/:db/:table?',
      name: 'browse',
      component: () => import('@/views/BrowseView.vue'),
      props: true,
      meta: { title: '数据浏览' },
    },
    {
      path: '/sync',
      name: 'sync',
      component: () => import('@/views/SyncView.vue'),
      meta: { title: '同步与备份' },
    },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
});

router.afterEach((to) => {
  const title = (to.meta.title as string | undefined) ?? '';
  document.title = (title ? title + ' · ' : '') + 'deepseekapp Web 数据台';
});
