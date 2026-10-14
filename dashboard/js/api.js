// ===========================
// DOSMAN UJIAN - API CLIENT v2
// ===========================

var API = {
  useProxy: function () {
    return window.location.hostname === "36.93.15.146" || window.location.hostname === "lms.sman1-gianyar.sch.id";
  },

  buildUrl: function (endpoint, params) {
    var query = new URLSearchParams(params);
    if (this.useProxy()) {
      query.set("_endpoint", endpoint);
      return "proxy.php?" + query.toString();
    }
    var moodleUrl = Auth.getMoodleUrl();
    var path =
      endpoint === "token" ? "/login/token.php" : "/webservice/rest/server.php";
    return moodleUrl + path + "?" + query.toString();
  },

  call: async function (wsfunction, params) {
    params = params || {};
    var token = Auth.getToken();
    var allParams = Object.assign(
      {
        wstoken: token,
        wsfunction: wsfunction,
        moodlewsrestformat: "json",
      },
      params,
    );

    var url = this.buildUrl("webservice", allParams);
    var response = await fetch(url);
    if (!response.ok) throw new Error("HTTP Error: " + response.status);

    var data = await response.json();
    if (data && data.exception) {
      if (data.errorcode === "invalidtoken") Auth.logout();
      throw new Error(data.message || data.exception);
    }
    return data;
  },

  getUserId: async function () {
    var stored = localStorage.getItem("dosman_userid");
    if (stored && stored !== "0" && stored !== "null" && stored !== "") {
      return parseInt(stored);
    }
    try {
      var info = await this.call("core_webservice_get_site_info", {});
      if (info && info.userid) {
        localStorage.setItem("dosman_userid", info.userid);
        localStorage.setItem("dosman_username", info.fullname || "Guru");
        return info.userid;
      }
    } catch (e) {
      console.warn("getUserId gagal:", e.message);
    }
    return 0;
  },

  getCourses: async function () {
    var token = Auth.getToken();
    var userid = await this.getUserId();

    // Cara 1: core_enrol_get_users_courses (course yang user ikuti)
    if (userid > 0) {
      try {
        var url = this.buildUrl("webservice", {
          wstoken: token,
          wsfunction: "core_enrol_get_users_courses",
          moodlewsrestformat: "json",
          userid: userid,
        });
        var res = await fetch(url);
        var data = await res.json();
        if (Array.isArray(data) && data.length > 0) {
          return data.filter(function (c) {
            return c.id > 1;
          });
        }
      } catch (e) {
        console.warn("core_enrol_get_users_courses:", e.message);
      }
    }

    // Cara 2: core_course_get_courses (semua course - butuh akses)
    try {
      var url2 = this.buildUrl("webservice", {
        wstoken: token,
        wsfunction: "core_course_get_courses",
        moodlewsrestformat: "json",
      });
      var res2 = await fetch(url2);
      var data2 = await res2.json();
      if (Array.isArray(data2) && data2.length > 0) {
        return data2.filter(function (c) {
          return c.id > 1;
        });
      }
    } catch (e) {
      console.warn("core_course_get_courses:", e.message);
    }

    return [];
  },

  getQuizzes: async function (courseId) {
    var data = await this.call("mod_quiz_get_quizzes_by_courses", {
      "courseids[0]": courseId,
    });
    return (data && data.quizzes) ? data.quizzes : [];
  },

  getLogs: async function (quizId, courseId, suspiciousOnly, userId) {
    return await this.call("local_dosman_ujian_get_logs", {
      quizid: quizId,
      courseid: courseId,
      userid: userId || 0,
      suspicious_only: suspiciousOnly ? 1 : 0,
      limit: 200,
    });
  },

  getSessions: async function (quizId, courseId) {
    return await this.call("local_dosman_ujian_get_sessions", {
      quizid: quizId,
      courseid: courseId,
    });
  },

  manageSession: async function (sessionId, courseId, action, reason) {
    return await this.call("local_dosman_ujian_manage_session", {
      session_id: sessionId,
      courseid: courseId,
      action: action,
      reason: reason || "",
    });
  },

  getClientConfig: async function () {
    return await this.call("local_dosman_ujian_get_client_config", {});
  },

  setClientConfig: async function (adminExitPassword) {
    return await this.call("local_dosman_ujian_set_client_config", {
      admin_exit_password: adminExitPassword || "",
    });
  },

  getAppStatus: async function () {
    try {
      var token = Auth.getToken();
      var res = await fetch('appstatus.php?token=' + encodeURIComponent(token));
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return await res.json();
    } catch (e) {
      console.warn('getAppStatus failed:', e.message);
      return {};
    }
  },

  /**
   * Ambil password keluar aplikasi langsung dari DB via pwd.php.
   * Return string kosong jika tidak ada password, null jika gagal fetch.
   */
};
