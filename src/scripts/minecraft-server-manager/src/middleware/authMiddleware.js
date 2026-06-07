"use strict";

const { tokenStore, TTL_MS } = require("../controllers/authController");

exports.isAuthenticated = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ message: "Missing or invalid Authorization header" });
  }

  const token = authHeader.split(" ")[1];
  const data  = tokenStore.get(token);

  if (!data) {
    return res.status(401).json({ message: "Invalid or expired token" });
  }

  // TTL_MS imported from authController — single source of truth
  if (Date.now() - data.created > TTL_MS) {
    tokenStore.delete(token);
    return res.status(401).json({ message: "Session expired" });
  }

  req.user = { username: data.username };
  next();
};
