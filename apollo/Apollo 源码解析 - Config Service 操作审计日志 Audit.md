# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/)

本文分享 Config Service **操作审计日志 Audit** 。在每次在做 ConfigDB 写操作( 增、删、改 )操作时，都会记录一条 Audit 日志，用于未来的审计追溯。

> 老艿艿：这种实践方式，非常适用于我们做的**管理平台**。

# 2. Audit

`com.ctrip.framework.apollo.biz.entity.Audit` ，继承 BaseEntity 抽象类，Audit **实体**。代码如下：

```java
@Entity
@Table(name = "Audit")
@SQLDelete(sql = "Update Audit set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Audit extends BaseEntity {

  public enum OP { // 操作枚举
    INSERT, UPDATE, DELETE
  }

  @Column(name = "EntityName", nullable = false)
  private String entityName; // 实体名

  @Column(name = "EntityId")
  private Long entityId; // 实体编号

  @Column(name = "OpName", nullable = false)
  private String opName;

  @Column(name = "Comment")
  private String comment;

  // ... 省略其他接口和属性
}
```

- `entityName` + `entityId` 字段，确实一个实体对象。
- `opName` 字段，操作**名**。分成 INSERT、UPDATE、DELETE 三种，在 **OP** 中枚举。
- `comment` 字段，备注。
- 例如：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649259344.png)

> 老艿艿：在**管理平台**中，我比较喜欢再增加几个字段
>
> - `ip` 字段，请求方的 IP 。
> - `ua` 字段，请求的 User-Agent 。
> - `extras` 字段，数据结果为 **Map** 进行 **JSON** 化，存储**重要**字段。例如，更新用户手机号，那么会存储 `mobile=15601691024` 到 `extras` 字段中。

# 3. AuditService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.AuditService` ，提供 Aduit 的 **Service** 逻辑给 Admin Service 和 Config Service 。

```java
@Service
public class AuditService {

  private final AuditRepository auditRepository;

  public AuditService(final AuditRepository auditRepository) {
    this.auditRepository = auditRepository;
  }

  List<Audit> findByOwner(String owner) {
    return auditRepository.findByOwner(owner);
  }

  List<Audit> find(String owner, String entity, String op) {
    return auditRepository.findAudits(owner, entity, op);
  }

  @Transactional
  void audit(String entityName, Long entityId, Audit.OP op, String owner) {
    Audit audit = new Audit();
    audit.setEntityName(entityName);
    audit.setEntityId(entityId);
    audit.setOpName(op.name());
    audit.setDataChangeCreatedBy(owner);
    auditRepository.save(audit);
  }

  @Transactional
  void audit(Audit audit){
    auditRepository.save(audit);
  }
}
```

# 4. AuditRepository

`com.ctrip.framework.apollo.biz.repository.AuditRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 Audit 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface AuditRepository extends PagingAndSortingRepository<Audit, Long> {

  @Query("SELECT a from Audit a WHERE a.dataChangeCreatedBy = :owner")
  List<Audit> findByOwner(@Param("owner") String owner);

  @Query("SELECT a from Audit a WHERE a.dataChangeCreatedBy = :owner AND a.entityName =:entity AND a.opName = :op")
  List<Audit> findAudits(@Param("owner") String owner, @Param("entity") String entity,
      @Param("op") String op);
}
```



# 参考

[Apollo 源码解析 —— Config Service 操作审计日志 Audit](https://www.iocoder.cn/Apollo/config-service-audit/)
