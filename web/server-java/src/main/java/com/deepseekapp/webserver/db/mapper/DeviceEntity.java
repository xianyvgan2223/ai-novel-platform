package com.deepseekapp.webserver.db.mapper;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;

/** 设备登记表（MyBatis-Plus 实体）。 */
@TableName("devices")
public class DeviceEntity {

    @TableId(value = "device_id", type = IdType.INPUT)
    private String deviceId;
    private String name;
    private String platform;
    private Long idBase;
    private String scopeDir;
    private Long lastSeenAt;
    private Long createdAt;

    public String getDeviceId() {
        return deviceId;
    }

    public void setDeviceId(String deviceId) {
        this.deviceId = deviceId;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public String getPlatform() {
        return platform;
    }

    public void setPlatform(String platform) {
        this.platform = platform;
    }

    public Long getIdBase() {
        return idBase;
    }

    public void setIdBase(Long idBase) {
        this.idBase = idBase;
    }

    public String getScopeDir() {
        return scopeDir;
    }

    public void setScopeDir(String scopeDir) {
        this.scopeDir = scopeDir;
    }

    public Long getLastSeenAt() {
        return lastSeenAt;
    }

    public void setLastSeenAt(Long lastSeenAt) {
        this.lastSeenAt = lastSeenAt;
    }

    public Long getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(Long createdAt) {
        this.createdAt = createdAt;
    }
}
