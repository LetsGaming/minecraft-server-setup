const express = require("express");
const router = express.Router();
const serverController = require("../controllers/serverController");
const { isAuthenticated } = require("../middleware/authMiddleware");

router.get("/status", serverController.status);
router.post("/start", isAuthenticated, serverController.start);
router.post("/shutdown", isAuthenticated, serverController.shutdown);
router.post("/restart", isAuthenticated, serverController.restart);
router.post("/smart-restart", isAuthenticated, serverController.smartRestart);
router.post("/rollback", isAuthenticated, serverController.rollback);
router.post("/command", isAuthenticated, serverController.sendCommand);

module.exports = router;
