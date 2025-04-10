document.addEventListener("DOMContentLoaded", function () {
  const popup = document.getElementById("popupOverlay");
  const downloadButtons = document.querySelectorAll(".download-uf2-button");
  const closeBtn = document.querySelector(".close-popup");
  const downloadBtn = document.querySelector(".demo-content button");

  downloadButtons.forEach((button) => {
    button.onclick = function () {
      popup.style.display = "block";
      downloadBtn.textContent = `Download UF2 - ${this.dataset.boardType}`;
      downloadBtn.dataset.uf2Link = this.dataset.uf2Link;
      document.addEventListener("keydown", handleEscapeKey);
    };
  });

  downloadBtn.onclick = function () {
    const link = document.createElement("a");
    link.href = this.dataset.uf2Link;
    link.download = "";
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  function handleEscapeKey(event) {
    if (event.key === "Escape") {
      popup.style.display = "none";
      // Remove event listener when popup closes
      document.removeEventListener("keydown", handleEscapeKey);
    }
  }

  closeBtn.onclick = function () {
    popup.style.display = "none";
    // Remove event listener when popup closes via button
    document.removeEventListener("keydown", handleEscapeKey);
  };

  window.onclick = function (event) {
    if (event.target == popup) {
      popup.style.display = "none";
      // Remove event listener when popup closes via outside click
      document.removeEventListener("keydown", handleEscapeKey);
    }
  };
});
