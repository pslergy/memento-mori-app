/**
 * Room Event Model (Sequelize)
 * Схема для событий комнат с составным первичным ключом
 */

module.exports = (sequelize, DataTypes) => {
  const RoomEvent = sequelize.define('RoomEvent', {
    id: {
      type: DataTypes.UUID,
      allowNull: false,
      primaryKey: true,
      comment: 'UUID события (часть составного ключа)'
    },
    roomId: {
      type: DataTypes.STRING,
      allowNull: false,
      primaryKey: true,
      field: 'room_id',
      comment: 'ID комнаты (часть составного ключа)'
    },
    type: {
      type: DataTypes.ENUM('JOIN_ROOM', 'LEAVE_ROOM', 'MESSAGE', 'EDIT'),
      allowNull: false,
      comment: 'Тип события'
    },
    userId: {
      type: DataTypes.STRING,
      allowNull: false,
      field: 'user_id',
      comment: 'ID пользователя, создавшего событие'
    },
    timestamp: {
      type: DataTypes.BIGINT,
      allowNull: false,
      comment: 'Временная метка события (milliseconds since epoch)'
    },
    payload: {
      type: DataTypes.TEXT,
      allowNull: true,
      comment: 'Дополнительные данные события (JSON)',
      get() {
        const raw = this.getDataValue('payload');
        return raw ? JSON.parse(raw) : null;
      },
      set(value) {
        this.setDataValue('payload', value ? JSON.stringify(value) : null);
      }
    },
    eventOrigin: {
      type: DataTypes.ENUM('LOCAL', 'MESH', 'SERVER'),
      allowNull: false,
      defaultValue: 'LOCAL',
      field: 'event_origin',
      comment: '📊 Источник события (только для диагностики)'
    },
    createdAt: {
      type: DataTypes.BIGINT,
      allowNull: false,
      defaultValue: () => Date.now(),
      field: 'created_at',
      comment: 'Время создания записи в БД'
    }
  }, {
    tableName: 'room_events',
    timestamps: false, // Используем createdAt вручную
    indexes: [
      {
        fields: ['room_id']
      },
      {
        fields: ['timestamp']
      },
      {
        fields: ['user_id']
      },
      {
        fields: ['type']
      },
      {
        fields: ['event_origin']
      },
      {
        unique: true,
        fields: ['room_id', 'id'],
        name: 'room_events_room_id_id_unique'
      }
    ]
  });
  
  RoomEvent.associate = (models) => {
    RoomEvent.belongsTo(models.Room, {
      foreignKey: 'roomId',
      as: 'room'
    });
    
    RoomEvent.belongsTo(models.User, {
      foreignKey: 'userId',
      as: 'user'
    });
  };
  
  return RoomEvent;
};
