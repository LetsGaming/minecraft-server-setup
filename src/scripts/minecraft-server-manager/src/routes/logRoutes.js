"use strict";

const express    = require("express");
const router     = express.Router();
const logController       = require("../controllers/logController");
const { isAuthenticated } = require("../middleware/authMiddleware");

// Log content can reveal server internals — require authentication.
router.get("/log", isAuthenticated, logController.getLogs);

module.exports = router;
