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
