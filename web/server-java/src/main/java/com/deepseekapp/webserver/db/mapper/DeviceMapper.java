package com.deepseekapp.webserver.db.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Mapper;

/**
 * 设备表 Mapper（MyBatis-Plus）。
 *
 * <p>这是后端持久层向 MyBatis-Plus 迁移的起点：新增或改造的数据访问优先走
 * {@code BaseMapper} + {@code QueryWrapper}，历史动态 SQL 再逐步收敛过来。</p>
 */
@Mapper
public interface DeviceMapper extends BaseMapper<DeviceEntity> {
}
