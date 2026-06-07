const express = require("express");
const router = express.Router();
const backupController = require("../controllers/backupController");
const { isAuthenticated } = require("../middleware/authMiddleware");

router.post("/backup", isAuthenticated, backupController.createBackup);
router.post("/restore", isAuthenticated, backupController.restoreBackup);
router.get("/list-backups", isAuthenticated, backupController.listBackups);
router.get("/download", isAuthenticated, backupController.downloadBackup);

module.exports = router;
